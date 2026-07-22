import { onRequest, onCall, HttpsError } from "firebase-functions/v2/https";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { setGlobalOptions } from "firebase-functions/v2";
import { defineSecret } from "firebase-functions/params";
import * as admin from "firebase-admin";
import { randomUUID, createHmac } from "crypto";
import { normalizeChatId, parseDateMs, wazzupSendText, wazzupSendMedia, wazzupEditText, wazzupDeleteMessage, type WazzupMessage, type WazzupStatus } from "./wazzup";

admin.initializeApp();
setGlobalOptions({ region: "europe-west1", maxInstances: 5 });

const WAZZUP_WEBHOOK_SECRET = defineSecret("WAZZUP_WEBHOOK_SECRET");
const WAZZUP_API_KEY = defineSecret("WAZZUP_API_KEY");
const WAZZUP_CHANNEL_ID = defineSecret("WAZZUP_CHANNEL_ID");

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

const REGION_HOST = "https://europe-west1-vip-client-manager.cloudfunctions.net";

/** Подпись пути медиа (чтобы mediaContent не отдавал произвольные файлы). */
function mediaToken(path: string, secret: string): string {
  return createHmac("sha256", secret).update(path).digest("hex");
}

/**
 * Публичная выдача медиа для Wazzup: стримит файл из Storage с чистыми
 * заголовками (cache-control: public), т.к. прямую ссылку firebasestorage
 * Wazzup не принимает («Bad response from content store»).
 */
export const mediaContent = onRequest({ secrets: [WAZZUP_WEBHOOK_SECRET] }, async (req, res) => {
  const path = String(req.query.path ?? "");
  const t = String(req.query.t ?? "");
  if (!path.startsWith("media/") || t !== mediaToken(path, WAZZUP_WEBHOOK_SECRET.value())) {
    res.status(401).send("unauthorized");
    return;
  }
  try {
    const file = admin.storage().bucket().file(path);
    const [meta] = await file.getMetadata();
    const [buf] = await file.download();
    res.set("Content-Type", (meta.contentType as string) ?? "application/octet-stream");
    res.set("Cache-Control", "public, max-age=3600");
    res.set("Accept-Ranges", "bytes");
    res.status(200).send(buf);
  } catch (e) {
    console.error("mediaContent error", e);
    res.status(404).send("not found");
  }
});

/** Фаза 0 — проверка деплоя. */
export const ping = onRequest((_req, res) => {
  res.json({ ok: true, service: "vip-crm-functions", ts: new Date().toISOString() });
});

/**
 * Приём вебхуков Wazzup → Firestore (Фаза 1).
 * Модель: contacts/{chatId}, conversations/{chatId}, messages/{messageId}.
 * messageId = ключ документа → авто-дедуп при повторной доставке.
 * ВНИМАНИЕ: вебхук Wazzup ещё указывает на Mac — эта функция тестируется
 * изолированно, пока не переключим (Фаза 3).
 */
export const wazzupWebhook = onRequest({ secrets: [WAZZUP_WEBHOOK_SECRET] }, async (req, res) => {
  const provided =
    (req.query.secret as string | undefined) ??
    (req.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "");
  if (provided !== WAZZUP_WEBHOOK_SECRET.value()) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }

  const body = (req.body ?? {}) as { test?: boolean; messages?: WazzupMessage[]; statuses?: WazzupStatus[] };
  if (body.test === true) {
    res.json({ ok: true });
    return;
  }

  const firestore = db();
  const messages = Array.isArray(body.messages) ? body.messages : [];
  const statuses = Array.isArray(body.statuses) ? body.statuses : [];

  try {
    for (const m of messages) {
      const chatType = m.chatType ?? "whatsapp";
      const chatId = normalizeChatId(chatType, String(m.chatId ?? ""));
      if (!chatId || !m.messageId) continue;

      const inbound = !m.isEcho;
      const type = m.type ?? "text";
      const text = m.text ?? null;
      const preview = text && text.length > 0 ? text : `[${type}]`;
      const ms = parseDateMs(m.dateTime);
      const createdAt = ms ? admin.firestore.Timestamp.fromMillis(ms) : ts();

      const batch = firestore.batch();

      // Контакт (идентификация по номеру — имя = номер, как в текущем CRM).
      batch.set(
        firestore.collection("contacts").doc(chatId),
        { phone: chatId, name: `+${chatId}`, chatType, channelId: m.channelId ?? null, lastMessageAt: createdAt, updatedAt: ts() },
        { merge: true },
      );

      // Диалог (один на контакт). unreadCount растёт только на входящих.
      const conv: Record<string, unknown> = {
        contactId: chatId,
        phone: chatId,
        name: `+${chatId}`,
        chatType,
        channelId: m.channelId ?? null,
        status: "open",
        lastMessageAt: createdAt,
        lastMessagePreview: preview,
        updatedAt: ts(),
      };
      if (inbound) conv.unreadCount = admin.firestore.FieldValue.increment(1);
      batch.set(firestore.collection("conversations").doc(chatId), conv, { merge: true });

      // Сообщение (ключ = messageId → идемпотентно).
      batch.set(
        firestore.collection("messages").doc(String(m.messageId)),
        {
          conversationId: chatId,
          chatId,
          externalMessageId: m.messageId,
          direction: inbound ? "inbound" : "outbound",
          type,
          text,
          contentUri: m.contentUri ?? null,
          status: inbound ? "received" : (m.status ?? "sent"),
          authorName: m.authorName ?? null,
          createdAt,
        },
        { merge: true },
      );

      await batch.commit();
    }

    // Статусы доставки/прочтения — обновляем сообщение по messageId.
    for (const s of statuses) {
      if (!s.messageId || !s.status) continue;
      await firestore
        .collection("messages")
        .doc(String(s.messageId))
        .set({ status: s.status, statusAt: ts() }, { merge: true });
    }

    res.json({ ok: true, messages: messages.length, statuses: statuses.length });
  } catch (e) {
    console.error("wazzupWebhook error", e);
    res.status(500).json({ error: "internal" });
  }
});

/**
 * Разовая инициализация: делает всех существующих Firebase Auth пользователей
 * админами (создаёт users/{uid}). Работает только если коллекция users пуста.
 * Защита — секрет вебхука в ?secret=.
 */
export const bootstrapAdmins = onRequest({ secrets: [WAZZUP_WEBHOOK_SECRET] }, async (req, res) => {
  if ((req.query.secret as string | undefined) !== WAZZUP_WEBHOOK_SECRET.value()) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  const firestore = db();
  const list = await admin.auth().listUsers(100);
  const created: string[] = [];
  const skipped: string[] = [];
  for (const u of list.users) {
    const ref = firestore.collection("users").doc(u.uid);
    const snap = await ref.get();
    if (snap.exists) {
      skipped.push(u.email ?? u.uid);
      continue;
    }
    await ref.set({
      email: u.email ?? "",
      name: u.displayName ?? (u.email ?? ""),
      role: "admin",
      isActive: true,
      createdAt: ts(),
    });
    created.push(u.email ?? u.uid);
  }
  const all = await firestore.collection("users").get();
  const existingDocs = all.docs.map((d) => ({ id: d.id, email: d.get("email"), role: d.get("role") }));
  res.json({ ok: true, created, skipped, usersDocsTotal: all.size, existingDocs });
});

/** Создать менеджера (callable, только админ): Firebase Auth + users/{uid}. */
export const createManager = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Требуется вход");
  const caller = await db().collection("users").doc(uid).get();
  const callerRole = caller.data()?.role;
  if (callerRole !== "admin" && callerRole !== "administrator") {
    throw new HttpsError("permission-denied", "Только админ");
  }

  const data = (request.data ?? {}) as { email?: string; name?: string; password?: string; role?: string };
  const email = (data.email ?? "").trim();
  const password = (data.password ?? "").trim();
  const name = (data.name ?? "").trim();
  if (!email || password.length < 6) throw new HttpsError("invalid-argument", "email и пароль (от 6) обязательны");
  const role = ["admin", "manager", "viewer"].includes(data.role ?? "") ? (data.role as string) : "manager";

  const user = await admin.auth().createUser({ email, password, displayName: name || undefined });
  await db().collection("users").doc(user.uid).set({ email, name, role, isActive: true, createdAt: ts() });
  return { ok: true, uid: user.uid };
});

/** Изменить менеджера (callable, только админ): имя/роль/активность/сброс пароля. */
export const updateManager = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Требуется вход");
  const caller = await db().collection("users").doc(callerUid).get();
  const cr = caller.data()?.role;
  if (cr !== "admin" && cr !== "administrator") throw new HttpsError("permission-denied", "Только админ");

  const data = (request.data ?? {}) as { uid?: string; name?: string; role?: string; isActive?: boolean; password?: string };
  const uid = (data.uid ?? "").trim();
  if (!uid) throw new HttpsError("invalid-argument", "uid обязателен");
  if (uid === callerUid && data.isActive === false) throw new HttpsError("failed-precondition", "Нельзя отключить самого себя");

  const authUpdate: Record<string, unknown> = {};
  if (data.isActive !== undefined) authUpdate.disabled = !data.isActive;
  if (data.password && data.password.length >= 6) authUpdate.password = data.password;
  if (data.name !== undefined) authUpdate.displayName = data.name;
  if (Object.keys(authUpdate).length > 0) await admin.auth().updateUser(uid, authUpdate);

  const docUpdate: Record<string, unknown> = { updatedAt: ts() };
  if (data.name !== undefined) docUpdate.name = data.name;
  if (data.role !== undefined && ["admin", "administrator", "manager", "viewer"].includes(data.role)) docUpdate.role = data.role;
  if (data.isActive !== undefined) docUpdate.isActive = data.isActive;
  await db().collection("users").doc(uid).set(docUpdate, { merge: true });

  return { ok: true };
});

/**
 * Отправка сообщения менеджером (callable, Фаза 2). Требует Firebase Auth.
 * Пишет сообщение в Firestore и отправляет через Wazzup.
 */
export const sendMessage = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { phone?: string; text?: string; name?: string; refMessageId?: string; replyToText?: string };
  const chatId = normalizeChatId("whatsapp", String(data.phone ?? ""));
  const text = (data.text ?? "").trim();
  if (!chatId || !text) throw new HttpsError("invalid-argument", "phone и text обязательны");
  const refMessageId = (data.refMessageId ?? "").trim() || undefined;

  const crmMessageId = randomUUID();
  const result = await wazzupSendText(WAZZUP_API_KEY.value(), {
    channelId: WAZZUP_CHANNEL_ID.value(),
    chatId,
    chatType: "whatsapp",
    text,
    crmMessageId,
    refMessageId,
  });
  const messageId = String(result.messageId ?? crmMessageId);
  const name = (data.name ?? "").trim() || `+${chatId}`;
  const firestore = db();

  await firestore.collection("messages").doc(messageId).set(
    {
      conversationId: chatId,
      chatId,
      externalMessageId: result.messageId ?? null,
      direction: "outbound",
      type: "text",
      text,
      status: "sent",
      authorId: request.auth.uid,
      crmMessageId,
      ...(refMessageId ? { replyToId: refMessageId, replyToText: (data.replyToText ?? "").slice(0, 200) } : {}),
      createdAt: ts(),
    },
    { merge: true },
  );
  await firestore.collection("contacts").doc(chatId).set(
    { phone: chatId, name, chatType: "whatsapp", lastMessageAt: ts(), updatedAt: ts() },
    { merge: true },
  );
  await firestore.collection("conversations").doc(chatId).set(
    { contactId: chatId, phone: chatId, name, chatType: "whatsapp", status: "open", unreadCount: 0, lastMessageAt: ts(), lastMessagePreview: text, updatedAt: ts() },
    { merge: true },
  );

  return { ok: true, messageId };
});

/**
 * Отправка медиа менеджером (callable). Файл уже загружен приложением в
 * Firebase Storage; сюда приходит публичная ссылка mediaUrl.
 */
export const sendMedia = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID, WAZZUP_WEBHOOK_SECRET] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { phone?: string; mediaPath?: string; mediaUrl?: string; type?: string; name?: string };
  const chatId = normalizeChatId("whatsapp", String(data.phone ?? ""));
  const mediaPath = (data.mediaPath ?? "").trim();
  const mediaUrl = (data.mediaUrl ?? "").trim();
  if (!chatId || !mediaPath) throw new HttpsError("invalid-argument", "phone и mediaPath обязательны");
  const type = data.type ?? "document";

  // Wazzup качает contentUri сам — даём чистую ссылку через нашу функцию.
  // ВАЖНО: слэши в path НЕ кодируем (%2F) — Google GFE отклоняет encoded slashes
  // до функции, и Wazzup получает «bad response». Наш path безопасен (a-z0-9/_.).
  const tok = mediaToken(mediaPath, WAZZUP_WEBHOOK_SECRET.value());
  const contentUri = `${REGION_HOST}/mediaContent?path=${mediaPath}&t=${tok}`;

  const crmMessageId = randomUUID();
  const result = await wazzupSendMedia(WAZZUP_API_KEY.value(), {
    channelId: WAZZUP_CHANNEL_ID.value(),
    chatId,
    chatType: "whatsapp",
    contentUri,
    crmMessageId,
  });
  const messageId = String(result.messageId ?? crmMessageId);
  const name = (data.name ?? "").trim() || `+${chatId}`;
  const firestore = db();

  await firestore.collection("messages").doc(messageId).set(
    {
      conversationId: chatId,
      chatId,
      externalMessageId: result.messageId ?? null,
      direction: "outbound",
      type,
      text: null,
      mediaUrl,
      status: "sent",
      authorId: request.auth.uid,
      crmMessageId,
      createdAt: ts(),
    },
    { merge: true },
  );
  await firestore.collection("contacts").doc(chatId).set(
    { phone: chatId, name, chatType: "whatsapp", lastMessageAt: ts(), updatedAt: ts() },
    { merge: true },
  );
  await firestore.collection("conversations").doc(chatId).set(
    { contactId: chatId, phone: chatId, name, chatType: "whatsapp", status: "open", unreadCount: 0, lastMessageAt: ts(), lastMessagePreview: `[${type}]`, updatedAt: ts() },
    { merge: true },
  );
  return { ok: true, messageId };
});

/** Редактирование своего сообщения (callable, §16): PATCH Wazzup + Firestore. */
export const editMessage = onCall({ secrets: [WAZZUP_API_KEY] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { messageId?: string; text?: string };
  const messageId = (data.messageId ?? "").trim();
  const text = (data.text ?? "").trim();
  if (!messageId || !text) throw new HttpsError("invalid-argument", "messageId и text обязательны");
  await wazzupEditText(WAZZUP_API_KEY.value(), messageId, text);
  await db().collection("messages").doc(messageId).set({ text, isEdited: true, updatedAt: ts() }, { merge: true });
  return { ok: true };
});

/** Удаление своего сообщения (callable, §16): DELETE Wazzup + пометка в Firestore. */
export const deleteMessage = onCall({ secrets: [WAZZUP_API_KEY] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { messageId?: string };
  const messageId = (data.messageId ?? "").trim();
  if (!messageId) throw new HttpsError("invalid-argument", "messageId обязателен");
  await wazzupDeleteMessage(WAZZUP_API_KEY.value(), messageId);
  await db().collection("messages").doc(messageId).set(
    { isDeleted: true, text: null, mediaUrl: null, contentUri: null, updatedAt: ts() },
    { merge: true },
  );
  return { ok: true };
});

/**
 * Входящее медиа: как только в messages появляется contentUri без mediaUrl —
 * скачиваем из Wazzup и кладём в Firebase Storage (durable), пишем публичную
 * ссылку mediaUrl в документ.
 */
export const onMessageMedia = onDocumentCreated("messages/{id}", async (event) => {
  const snap = event.data;
  if (!snap) return;
  const d = snap.data();
  const contentUri = d.contentUri as string | undefined;
  if (!contentUri || d.mediaUrl) return;

  try {
    const res = await fetch(contentUri);
    if (!res.ok) return;
    const buf = Buffer.from(await res.arrayBuffer());
    const contentType = res.headers.get("content-type") ?? "application/octet-stream";
    const bucket = admin.storage().bucket();
    const token = randomUUID();
    const path = `media/in/${event.params.id}`;
    await bucket.file(path).save(buf, {
      metadata: { contentType, metadata: { firebaseStorageDownloadTokens: token } },
    });
    const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(path)}?alt=media&token=${token}`;
    await snap.ref.set({ mediaUrl: url, mediaContentType: contentType }, { merge: true });
  } catch (e) {
    console.error("onMessageMedia error", e);
  }
});
