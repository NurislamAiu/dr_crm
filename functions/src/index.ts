import { onRequest, onCall, HttpsError } from "firebase-functions/v2/https";
import { setGlobalOptions } from "firebase-functions/v2";
import { defineSecret } from "firebase-functions/params";
import * as admin from "firebase-admin";
import { randomUUID } from "crypto";
import { normalizeChatId, parseDateMs, wazzupSendText, type WazzupMessage, type WazzupStatus } from "./wazzup";

admin.initializeApp();
setGlobalOptions({ region: "europe-west1", maxInstances: 5 });

const WAZZUP_WEBHOOK_SECRET = defineSecret("WAZZUP_WEBHOOK_SECRET");
const WAZZUP_API_KEY = defineSecret("WAZZUP_API_KEY");
const WAZZUP_CHANNEL_ID = defineSecret("WAZZUP_CHANNEL_ID");

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

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
  const existing = await firestore.collection("users").limit(1).get();
  if (!existing.empty) {
    res.json({ ok: true, skipped: true, note: "users уже существуют" });
    return;
  }
  const list = await admin.auth().listUsers(100);
  const created: string[] = [];
  for (const u of list.users) {
    await firestore.collection("users").doc(u.uid).set({
      email: u.email ?? "",
      name: u.displayName ?? (u.email ?? ""),
      role: "admin",
      isActive: true,
      createdAt: ts(),
    });
    created.push(u.email ?? u.uid);
  }
  res.json({ ok: true, created });
});

/** Создать менеджера (callable, только админ): Firebase Auth + users/{uid}. */
export const createManager = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Требуется вход");
  const caller = await db().collection("users").doc(uid).get();
  if (caller.data()?.role !== "admin") throw new HttpsError("permission-denied", "Только админ");

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

/**
 * Отправка сообщения менеджером (callable, Фаза 2). Требует Firebase Auth.
 * Пишет сообщение в Firestore и отправляет через Wazzup.
 */
export const sendMessage = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { phone?: string; text?: string; name?: string };
  const chatId = normalizeChatId("whatsapp", String(data.phone ?? ""));
  const text = (data.text ?? "").trim();
  if (!chatId || !text) throw new HttpsError("invalid-argument", "phone и text обязательны");

  const crmMessageId = randomUUID();
  const result = await wazzupSendText(WAZZUP_API_KEY.value(), {
    channelId: WAZZUP_CHANNEL_ID.value(),
    chatId,
    chatType: "whatsapp",
    text,
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
      type: "text",
      text,
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
    { contactId: chatId, phone: chatId, name, chatType: "whatsapp", status: "open", unreadCount: 0, lastMessageAt: ts(), lastMessagePreview: text, updatedAt: ts() },
    { merge: true },
  );

  return { ok: true, messageId };
});
