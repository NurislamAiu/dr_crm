import { onRequest, onCall, HttpsError } from "firebase-functions/v2/https";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { setGlobalOptions } from "firebase-functions/v2";
import { defineSecret } from "firebase-functions/params";
import * as admin from "firebase-admin";
import { randomUUID, createHmac } from "crypto";
import { normalizeChatId, parseDateMs, wazzupSendText, wazzupSendMedia, wazzupEditText, wazzupDeleteMessage, type WazzupMessage, type WazzupStatus } from "./wazzup";
import { auditOutbound, dayKey, fingerprint, hasLink, isNight, loadAllowedPhones, logRisk, peekChat, textFlags, type RiskKind } from "./risk";
import { enqueue, gateSend, limits, reserveSlot } from "./limits";

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
export const wazzupWebhook = onRequest({ secrets: [WAZZUP_WEBHOOK_SECRET, WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (req, res) => {
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
  const inboundChats = new Set<string>();
  const missedCallChats = new Set<string>();
  // Пуш-уведомления менеджерам о входящих.
  const pushItems: { chatId: string; title: string; body: string }[] = [];

  try {
    for (const m of messages) {
      const chatType = m.chatType ?? "whatsapp";
      const chatId = normalizeChatId(chatType, String(m.chatId ?? ""));
      if (!chatId || !m.messageId) continue;

      const inbound = !m.isEcho;
      const type = m.type ?? "text";
      if (inbound) inboundChats.add(chatId);
      if (inbound && type === "missing_call") missedCallChats.add(chatId);
      const text = m.text ?? null;
      const preview = text && text.length > 0 ? text : `[${type}]`;
      if (inbound && type !== "missing_call") {
        const kindLabel: Record<string, string> = { image: "📷 Фото", audio: "🎤 Голосовое", video: "🎬 Видео", document: "📄 Файл" };
        pushItems.push({ chatId, title: `CRM · ${fmtPhone(chatId)}`, body: (text && text.length > 0 ? text : (kindLabel[type] ?? `[${type}]`)).slice(0, 140) });
      }
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
      conv.lastOutbound = !inbound;
      conv.lastAuthorId = null;
      // Имя автора из Wazzup (менеджер ответил из интерфейса Wazzup/WhatsApp).
      conv.lastAuthorName = inbound ? null : (m.authorName ?? null);
      if (inbound) {
        conv.unreadCount = admin.firestore.FieldValue.increment(1);
        // Клиент нам писал — значит контакт «тёплый» (контроль подозрительной
        // активности не считает такие чаты холодной рассылкой).
        conv.hasInbound = true;
      }
      batch.set(firestore.collection("conversations").doc(chatId), conv, { merge: true });

      // Эхо нашего исходящего приходит с ДРУГИМ messageId — иначе в чате
      // появляется дубль. Ищем уже записанное нами сообщение (у него есть
      // crmMessageId) с тем же текстом за последние 5 минут и обновляем его.
      let twinRef: FirebaseFirestore.DocumentReference | null = null;
      if (!inbound && text && text.length > 0) {
        const nowMs = ms ?? Date.now();
        const recent = await firestore
          .collection("messages")
          .where("conversationId", "==", chatId)
          .orderBy("createdAt", "desc")
          .limit(15)
          .get();
        for (const d of recent.docs) {
          if (d.id === String(m.messageId)) { twinRef = null; break; }
          const x = d.data();
          if (x.direction !== "outbound" || !x.crmMessageId) continue;
          if ((x.text ?? "") !== text) continue;
          const tms = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          if (Math.abs(tms - nowMs) > 5 * 60000) continue;
          twinRef = d.ref;
          break;
        }
      }

      if (twinRef) {
        // Это эхо уже сохранённого сообщения — только дополняем.
        batch.set(
          twinRef,
          { externalMessageId: m.messageId, status: m.status ?? "sent", echoMessageId: m.messageId },
          { merge: true },
        );
      } else {
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
      }

      await batch.commit();
    }

    // Статусы доставки/прочтения. ВАЖНО: set() создавал бы пустой документ,
    // если сообщения с таким id нет (у нашего исходящего id другой) — а он
    // потом висел бы в чате пустым «сообщением». Поэтому обновляем только
    // существующие, иначе ищем по externalMessageId.
    for (const s of statuses) {
      if (!s.messageId || !s.status) continue;
      const ref = firestore.collection("messages").doc(String(s.messageId));
      const snap = await ref.get();
      if (snap.exists) {
        await ref.set({ status: s.status, statusAt: ts() }, { merge: true });
        continue;
      }
      const found = await firestore
        .collection("messages")
        .where("externalMessageId", "==", String(s.messageId))
        .limit(1)
        .get();
      if (!found.empty) {
        await found.docs[0]!.ref.set({ status: s.status, statusAt: ts() }, { merge: true });
      }
    }

    // Автоответчик (best-effort, не ломает приём при ошибке).
    for (const cid of inboundChats) {
      try {
        await maybeAutoReply(cid, WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value());
      } catch (e) {
        console.error("autoReply error", e);
      }
    }
    // Автоответ на пропущенный звонок.
    for (const cid of missedCallChats) {
      try {
        await maybeMissedCallReply(cid, WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value());
      } catch (e) {
        console.error("missedCallReply error", e);
      }
    }

    // Пуши менеджерам (best-effort).
    for (const cid of missedCallChats) {
      pushItems.push({ chatId: cid, title: "CRM · 📵 Пропущенный звонок", body: fmtPhone(cid) });
    }
    try {
      await pushToOfflineManagers(pushItems);
    } catch (e) {
      console.error("push error", e);
    }

    res.json({ ok: true, messages: messages.length, statuses: statuses.length });
  } catch (e) {
    console.error("wazzupWebhook error", e);
    res.status(500).json({ error: "internal" });
  }
});

/** «77473193061» → «+7 747 319-30-61» (для заголовков пушей). */
function fmtPhone(chatId: string): string {
  const d = chatId.replace(/\D/g, "");
  if (d.length === 11 && (d.startsWith("7") || d.startsWith("8"))) {
    const n = d.startsWith("8") ? `7${d.slice(1)}` : d;
    return `+7 ${n.slice(1, 4)} ${n.slice(4, 7)}-${n.slice(7, 9)}-${n.slice(9)}`;
  }
  return `+${d}`;
}

/**
 * Пуш-уведомления менеджерам, которые сейчас НЕ в приложении (presence).
 * Токены — fcmTokens/{uid}.tokens (array). Мёртвые токены вычищаются.
 */
async function pushToOfflineManagers(rawItems: { chatId: string; title: string; body: string }[]): Promise<void> {
  if (rawItems.length === 0) return;
  const firestore = db();

  // Заблокированные контакты — без пушей.
  const chatIds = [...new Set(rawItems.map((i) => i.chatId))];
  const convDocs = await Promise.all(chatIds.map((id) => firestore.doc(`conversations/${id}`).get()));
  const blockedIds = new Set(convDocs.filter((d) => d.data()?.blocked === true).map((d) => d.id));
  const items = rawItems.filter((i) => !blockedIds.has(i.chatId));
  if (items.length === 0) return;

  // Кто сейчас онлайн — им пуш не нужен (они видят чат).
  const presence = await firestore.collection("presence").where("online", "==", true).get();
  const now = Date.now();
  const onlineUids = new Set(
    presence.docs
      .filter((d) => {
        const ls = (d.data().lastSeen as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        return now - ls < 120000;
      })
      .map((d) => d.id),
  );

  const tokensSnap = await firestore.collection("fcmTokens").get();
  const tokens: string[] = [];
  const ownerOf: Record<string, string> = {};
  for (const d of tokensSnap.docs) {
    if (onlineUids.has(d.id)) continue;
    if (d.data().enabled === false) continue; // менеджер отключил уведомления
    const list = (d.data().tokens ?? []) as unknown[];
    for (const t of list) {
      if (typeof t === "string" && t.length > 0) {
        tokens.push(t);
        ownerOf[t] = d.id;
      }
    }
  }
  console.log(`push: items=${items.length} onlineUids=${JSON.stringify([...onlineUids])} tokenDocs=${tokensSnap.size} tokens=${tokens.length}`);
  if (tokens.length === 0) return;

  for (const it of items) {
    const resp = await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title: it.title, body: it.body },
      data: { chatId: it.chatId, name: it.title, phone: it.chatId },
      apns: { payload: { aps: { sound: "default", badge: 1 } } },
      android: { priority: "high", notification: { sound: "default" } },
    });
    console.log(`push "${it.title}": ok=${resp.successCount} fail=${resp.failureCount} errors=${JSON.stringify(resp.responses.filter((r) => !r.success).map((r) => r.error?.code))}`);
    // Чистим невалидные токены (переустановка приложения и т.п.).
    const dead: Record<string, string[]> = {};
    resp.responses.forEach((r, i) => {
      const code = r.error?.code ?? "";
      const t = tokens[i];
      if (!t || r.success) return;
      if (code.includes("registration-token-not-registered") || code.includes("invalid-registration-token") || code.includes("invalid-argument")) {
        const uid = ownerOf[t];
        if (uid) (dead[uid] ??= []).push(t);
      }
    });
    for (const [uid, list] of Object.entries(dead)) {
      await firestore
        .collection("fcmTokens")
        .doc(uid)
        .set({ tokens: admin.firestore.FieldValue.arrayRemove(...list) }, { merge: true })
        .catch(() => {});
    }
  }
}

/**
 * Автоответ на входящее (config/autoReply): текст, только вне рабочих часов
 * (опц.), кулдаун на диалог — чтобы не спамить.
 */
async function maybeAutoReply(chatId: string, apiKey: string, channelId: string): Promise<void> {
  const firestore = db();
  const cfg = (await firestore.doc("config/autoReply").get()).data();
  if (!cfg || cfg.enabled !== true || !cfg.text) return;

  if (cfg.outsideHoursOnly === true) {
    const tz = typeof cfg.tzOffset === "number" ? cfg.tzOffset : 5;
    const localHour = (new Date().getUTCHours() + tz + 24) % 24;
    const ws = typeof cfg.workStart === "number" ? cfg.workStart : 9;
    const we = typeof cfg.workEnd === "number" ? cfg.workEnd : 20;
    const withinWork = ws <= we ? localHour >= ws && localHour < we : localHour >= ws || localHour < we;
    if (withinWork) return; // в рабочее время не автоотвечаем
  }

  const convRef = firestore.doc(`conversations/${chatId}`);
  const conv = (await convRef.get()).data();
  if (conv?.blocked === true) return; // заблокирован — не автоотвечаем
  const cooldownMin = typeof cfg.cooldownMin === "number" ? cfg.cooldownMin : 360;
  const last = (conv?.lastAutoReplyAt as admin.firestore.Timestamp | undefined)?.toDate();
  if (last && Date.now() - last.getTime() < cooldownMin * 60000) return;

  const crmMessageId = randomUUID();
  const res = await wazzupSendText(apiKey, { channelId, chatId, chatType: "whatsapp", text: cfg.text as string, crmMessageId });
  const messageId = String(res.messageId ?? crmMessageId);

  await firestore.collection("messages").doc(messageId).set(
    {
      conversationId: chatId,
      chatId,
      externalMessageId: res.messageId ?? null,
      direction: "outbound",
      type: "text",
      text: cfg.text,
      status: "sent",
      authorId: "auto",
      isAuto: true,
      crmMessageId,
      createdAt: ts(),
    },
    { merge: true },
  );
  await convRef.set(
    {
      lastAutoReplyAt: ts(), lastMessageAt: ts(), lastMessagePreview: (cfg.text as string).slice(0, 120),
      lastOutbound: true, lastAuthorId: "auto", lastAuthorName: null,
    },
    { merge: true },
  );
}

/** Автоответ на пропущенный звонок (config/autoReply.missedCall*). Кулдаун 60 мин. */
async function maybeMissedCallReply(chatId: string, apiKey: string, channelId: string): Promise<void> {
  const firestore = db();
  const cfg = (await firestore.doc("config/autoReply").get()).data();
  if (!cfg || cfg.missedCallEnabled !== true || !cfg.missedCallText) return;

  const convRef = firestore.doc(`conversations/${chatId}`);
  const conv = (await convRef.get()).data();
  if (conv?.blocked === true) return; // заблокирован — не автоотвечаем
  const last = (conv?.lastMissedReplyAt as admin.firestore.Timestamp | undefined)?.toDate();
  if (last && Date.now() - last.getTime() < 60 * 60000) return;

  const crmMessageId = randomUUID();
  const res = await wazzupSendText(apiKey, { channelId, chatId, chatType: "whatsapp", text: cfg.missedCallText as string, crmMessageId });
  const messageId = String(res.messageId ?? crmMessageId);
  await firestore.collection("messages").doc(messageId).set(
    {
      conversationId: chatId,
      chatId,
      externalMessageId: res.messageId ?? null,
      direction: "outbound",
      type: "text",
      text: cfg.missedCallText,
      status: "sent",
      authorId: "auto",
      isAuto: true,
      crmMessageId,
      createdAt: ts(),
    },
    { merge: true },
  );
  await convRef.set(
    { lastMissedReplyAt: ts(), lastMessageAt: ts(), lastMessagePreview: (cfg.missedCallText as string).slice(0, 120) },
    { merge: true },
  );
}

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
/**
 * Ремонт профилей менеджеров: показывает, у кого из пользователей Firebase Auth
 * пропал документ users/{uid} (после случайного удаления в консоли), и по
 * запросу восстанавливает его. Вход в приложение без такого документа
 * невозможен — правила Firestore не пускают.
 *
 * Список:      GET /repairManagers?secret=<webhook secret>
 * Восстановить: GET /repairManagers?secret=...&email=user2@gmail.com&name=Асель&role=manager
 */
export const repairManagers = onRequest({ secrets: [WAZZUP_WEBHOOK_SECRET] }, async (req, res) => {
  if ((req.query.secret as string | undefined) !== WAZZUP_WEBHOOK_SECRET.value()) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  const firestore = db();
  const email = String(req.query.email ?? "").trim().toLowerCase();

  if (email) {
    try {
      const user = await admin.auth().getUserByEmail(email);
      const name = String(req.query.name ?? "").trim() || (user.displayName ?? email.split("@")[0] ?? "Менеджер");
      const role = String(req.query.role ?? "manager").trim() || "manager";
      await firestore.collection("users").doc(user.uid).set(
        { email, name, role, isActive: true, restoredAt: ts() },
        { merge: true },
      );
      res.json({ ok: true, restored: { uid: user.uid, email, name, role } });
    } catch (e) {
      res.status(404).json({ ok: false, error: String(e instanceof Error ? e.message : e) });
    }
    return;
  }

  // Отчёт: кто есть в Auth и у кого нет профиля + «осиротевшие» профили,
  // у которых пользователь Auth удалён (их правка падает с INTERNAL).
  const list = await admin.auth().listUsers(200);
  const authUids = new Set(list.users.map((u) => u.uid));
  const rows = await Promise.all(
    list.users.map(async (u) => {
      const doc = await firestore.collection("users").doc(u.uid).get();
      const d = doc.data();
      return {
        uid: u.uid,
        email: u.email ?? "",
        hasProfile: doc.exists,
        name: (d?.name as string) ?? "",
        role: (d?.role as string) ?? "",
        isActive: d?.isActive !== false,
      };
    }),
  );

  const profiles = await firestore.collection("users").get();
  const orphans = profiles.docs
    .filter((d) => !authUids.has(d.id))
    .map((d) => ({ uid: d.id, email: (d.data().email as string) ?? "", name: (d.data().name as string) ?? "" }));

  // ?cleanup=1 — пометить профили без пользователя Auth отключёнными.
  // Не удаляем: на эти uid ссылается история сообщений и аналитика.
  if (req.query.cleanup === "1" && orphans.length) {
    const batch = firestore.batch();
    for (const o of orphans) {
      batch.set(
        firestore.collection("users").doc(o.uid),
        { isActive: false, authDeleted: true, updatedAt: ts() },
        { merge: true },
      );
    }
    await batch.commit();
  }

  res.json({
    ok: true,
    total: rows.length,
    broken: rows.filter((r) => !r.hasProfile).length,
    users: rows,
    orphans,
    cleaned: req.query.cleanup === "1" ? orphans.length : 0,
  });
});

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
  if (Object.keys(authUpdate).length > 0) {
    try {
      await admin.auth().updateUser(uid, authUpdate);
    } catch (e) {
      // Пользователя удалили в консоли Firebase — раньше это падало как INTERNAL.
      const code = (e as { code?: string }).code ?? "";
      if (code.includes("user-not-found")) {
        throw new HttpsError(
          "not-found",
          "Этот менеджер удалён из Firebase Auth. Удалите его в списке и создайте заново.",
        );
      }
      throw new HttpsError("internal", String(e instanceof Error ? e.message : e));
    }
  }

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
/**
 * Общая отправка текста: Wazzup + записи в messages/contacts/conversations.
 * Используется callable sendMessage и серверной рассылкой.
 */
async function sendOutboundText(
  apiKey: string,
  channelId: string,
  p: { phone: string; text: string; name?: string; authorId: string; refMessageId?: string; replyToText?: string; isBroadcast?: boolean },
): Promise<{ messageId: string; queued: boolean }> {
  const chatId = normalizeChatId("whatsapp", p.phone);
  const text = p.text.trim();
  if (!chatId || !text) throw new Error("phone и text обязательны");

  // Состояние диалога ДО записи (для проверки «холодный контакт»).
  const pre = p.isBroadcast ? null : await peekChat(chatId);

  const crmMessageId = randomUUID();

  // Лимит темпа: сверх нормы (или «один текст многим») — в очередь.
  const gate = await gateSend({ authorId: p.authorId, chatId, text, broadcast: p.isBroadcast });
  if (!gate.send) {
    // Рассылка сама себе очередь: пусть попробует в следующую минуту.
    if (p.isBroadcast) throw new Error("RATE_LIMIT");
    await enqueue({
      kind: "text",
      chatId,
      text,
      name: p.name,
      authorId: p.authorId,
      refMessageId: p.refMessageId,
      replyToText: p.replyToText,
      crmMessageId,
      reason: gate.reason,
    });
    if (pre) {
      await auditOutbound({ authorId: p.authorId, chatId, text, messageId: crmMessageId, cold: pre.cold, flags: gate.flags });
    }
    return { messageId: crmMessageId, queued: true };
  }

  const result = await wazzupSendText(apiKey, {
    channelId,
    chatId,
    chatType: "whatsapp",
    text,
    crmMessageId,
    refMessageId: p.refMessageId,
  });
  const messageId = String(result.messageId ?? crmMessageId);
  const name = (p.name ?? "").trim() || `+${chatId}`;
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
      authorId: p.authorId,
      crmMessageId,
      ...(p.isBroadcast ? { isBroadcast: true } : {}),
      ...(p.refMessageId ? { replyToId: p.refMessageId, replyToText: (p.replyToText ?? "").slice(0, 200) } : {}),
      createdAt: ts(),
    },
    { merge: true },
  );
  await firestore.collection("contacts").doc(chatId).set(
    { phone: chatId, name, chatType: "whatsapp", lastMessageAt: ts(), updatedAt: ts() },
    { merge: true },
  );
  await firestore.collection("conversations").doc(chatId).set(
    {
      contactId: chatId, phone: chatId, name, chatType: "whatsapp", status: "open", unreadCount: 0,
      lastMessageAt: ts(), lastMessagePreview: text,
      // Кто ответил последним — показываем в списке чатов.
      lastOutbound: true, lastAuthorId: p.authorId, lastAuthorName: null,
      updatedAt: ts(),
    },
    { merge: true },
  );

  // Контроль подозрительной активности (не ломает отправку при ошибке).
  if (pre) {
    await auditOutbound({ authorId: p.authorId, chatId, text, messageId, cold: pre.cold, flags: gate.flags });
  }
  return { messageId, queued: false };
}

export const sendMessage = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { phone?: string; text?: string; name?: string; refMessageId?: string; replyToText?: string };
  try {
    const res = await sendOutboundText(WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value(), {
      phone: String(data.phone ?? ""),
      text: data.text ?? "",
      name: data.name,
      authorId: request.auth.uid,
      refMessageId: (data.refMessageId ?? "").trim() || undefined,
      replyToText: data.replyToText,
    });
    return { ok: true, messageId: res.messageId, queued: res.queued };
  } catch (e) {
    throw new HttpsError("invalid-argument", String(e instanceof Error ? e.message : e));
  }
});

/**
 * Состояние WhatsApp-канала в Wazzup (active / qridle / disabled и т.п.).
 * Нужно, чтобы менеджеры сразу видели, что номер отвалился и сообщения
 * не уходят.
 */
export const channelStatus = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  try {
    const res = await fetch("https://api.wazzup24.com/v3/channels", {
      headers: { Authorization: `Bearer ${WAZZUP_API_KEY.value()}` },
    });
    if (!res.ok) return { ok: false, state: "unknown", error: `HTTP ${res.status}` };
    const body = (await res.json()) as unknown;
    const list = (Array.isArray(body) ? body : ((body as { data?: unknown[] }).data ?? [])) as Record<string, unknown>[];
    const want = WAZZUP_CHANNEL_ID.value();
    const ch = list.find((c) => c.channelId === want) ?? list[0];
    if (!ch) return { ok: false, state: "unknown", error: "Канал не найден" };
    return {
      ok: true,
      state: String(ch.state ?? "unknown"),
      phone: String(ch.plainId ?? ch.name ?? ""),
      transport: String(ch.transport ?? ""),
    };
  } catch (e) {
    return { ok: false, state: "unknown", error: String(e instanceof Error ? e.message : e) };
  }
});

// ── Серверная рассылка ────────────────────────────────────────────────────

type BroadcastRow = { name: string; phone: string; date: string; status: string; variant?: number; error?: string };

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** Пуш создателю рассылки о завершении (независимо от presence). */
async function pushBroadcastDone(createdBy: string, sent: number, failed: number): Promise<void> {
  try {
    const doc = await db().collection("fcmTokens").doc(createdBy).get();
    const d = doc.data();
    if (!d || d.enabled === false) return;
    const tokens = ((d.tokens ?? []) as unknown[]).filter((t): t is string => typeof t === "string");
    if (!tokens.length) return;
    await admin.messaging().sendEachForMulticast({
      tokens,
      notification: { title: "CRM · Рассылка завершена", body: `Отправлено: ${sent} ✓${failed > 0 ? ` · ошибок: ${failed}` : ""}` },
      apns: { payload: { aps: { sound: "default" } } },
      android: { priority: "high" },
    });
  } catch (e) {
    console.error("pushBroadcastDone error", e);
  }
}

/**
 * Обработчик рассылок: раз в минуту берёт активную (status=running) и шлёт
 * до 3 сообщений с паузой delaySec между ними. Паузы не сжимаются, дубли
 * исключены (каждая строка помечается sent/failed до перехода к следующей).
 * maxInstances 1 — единственный обработчик, гонок нет.
 */
export const processBroadcasts = onSchedule(
  { schedule: "every 1 minutes", secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID], timeoutSeconds: 120, maxInstances: 1 },
  async () => {
    const firestore = db();
    const snap = await firestore.collection("broadcasts").where("status", "==", "running").limit(1).get();
    if (snap.empty) return;
    const first = snap.docs[0];
    if (!first) return;
    const ref = first.ref;
    const startedAt = Date.now();

    for (let k = 0; k < 3; k++) {
      const fresh = await ref.get();
      const b = fresh.data();
      if (!b || b.status !== "running") return;

      const rows = (b.rows ?? []) as BroadcastRow[];

      // Журнал: кто запустил рассылку, на скольких и с какой паузой.
      if (b.riskLogged !== true) {
        const delaySec = typeof b.delaySec === "number" ? b.delaySec : 20;
        const firstText = ((b.variants ?? []) as unknown[]).find((v): v is string => typeof v === "string") ?? "";
        await logRisk({
          authorId: String(b.createdBy ?? ""),
          kinds: rows.length > 30 || delaySec < 15 ? ["blast", "burst"] : ["blast"],
          text: firstText,
          count: rows.length,
          docId: `blast_${ref.id}`,
        }).catch(() => {});
        await ref.update({ riskLogged: true });
      }

      const idx = rows.findIndex((r) => r.status === "pending");
      if (idx < 0) {
        const sent = rows.filter((r) => r.status === "sent").length;
        const failed = rows.filter((r) => r.status === "failed").length;
        await ref.update({ status: "done", finishedAt: ts(), updatedAt: ts() });
        await pushBroadcastDone(String(b.createdBy ?? ""), sent, failed);
        return;
      }

      // Выдерживаем паузу от предыдущей отправки (никогда не короче delaySec).
      const delayMs = (typeof b.delaySec === "number" ? b.delaySec : 20) * 1000;
      const lastMs = (b.lastSentAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      const waitMs = lastMs + delayMs - Date.now();
      if (waitMs > 0) {
        // Если ожидание не влезает в этот запуск — доотправит следующий (через минуту).
        if (Date.now() - startedAt + waitMs > 90_000) return;
        await sleep(waitMs);
      }

      const variants = ((b.variants ?? []) as unknown[]).filter((v): v is string => typeof v === "string" && v.trim().length > 0);
      if (!variants.length) {
        await ref.update({ status: "error", error: "Нет текстов", updatedAt: ts() });
        return;
      }
      const mode = String(b.mode ?? "rotate");
      const done = rows.filter((r) => r.status !== "pending").length;
      const vIdx = mode === "single"
        ? Math.min(typeof b.singleIndex === "number" ? b.singleIndex : 0, variants.length - 1)
        : mode === "random"
          ? Math.floor(Math.random() * variants.length)
          : done % variants.length;

      const row = rows[idx];
      const tpl = variants[vIdx] ?? variants[0] ?? "";
      if (!row) return;
      const text = tpl.replaceAll("{name}", row.name).replaceAll("{date}", row.date);
      try {
        await sendOutboundText(WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value(), {
          phone: row.phone,
          text,
          name: row.name,
          authorId: String(b.createdBy ?? "broadcast"),
          isBroadcast: true,
        });
        rows[idx] = { ...row, status: "sent", variant: vIdx + 1 };
      } catch (e) {
        const msg = String(e instanceof Error ? e.message : e);
        // Упёрлись в лимит темпа — строка остаётся pending, дошлём позже.
        if (msg.includes("RATE_LIMIT")) {
          await ref.update({ waitingLimit: true, updatedAt: ts() });
          return;
        }
        rows[idx] = { ...row, status: "failed", variant: vIdx + 1, error: msg.slice(0, 200) };
      }
      const sent = rows.filter((r) => r.status === "sent").length;
      const failed = rows.filter((r) => r.status === "failed").length;
      await ref.update({ rows, sent, failed, lastSentAt: ts(), updatedAt: ts() });

      if (!rows.some((r) => r.status === "pending")) {
        await ref.update({ status: "done", finishedAt: ts(), updatedAt: ts() });
        await pushBroadcastDone(String(b.createdBy ?? ""), sent, failed);
        return;
      }
      if (Date.now() - startedAt > 80_000) return;
    }
  },
);

/**
 * Досылка очереди: раз в минуту берёт накопившиеся сообщения и отправляет их
 * ровным темпом, пока есть запас по лимиту канала. Так серия однотипных
 * сообщений растягивается во времени вместо всплеска, за который банят.
 * maxInstances 1 — очередь разбирает ровно один обработчик.
 */
export const processOutbox = onSchedule(
  { schedule: "every 1 minutes", secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID, WAZZUP_WEBHOOK_SECRET], timeoutSeconds: 120, maxInstances: 1 },
  async () => {
    const firestore = db();
    const lim = await limits();
    const snap = await firestore
      .collection("outbox")
      .where("status", "==", "pending")
      .orderBy("createdAt", "asc")
      .limit(30)
      .get();
    if (snap.empty) return;

    const startedAt = Date.now();
    for (const doc of snap.docs) {
      if (Date.now() - startedAt > 85_000) return;
      const slot = await reserveSlot();
      if (!slot.allow) return; // лимит исчерпан — продолжим через минуту

      const it = doc.data() as Record<string, unknown>;
      const chatId = String(it.chatId ?? "");
      const crmMessageId = String(it.crmMessageId ?? doc.id);
      try {
        let messageId = crmMessageId;
        if (it.kind === "media") {
          const mediaPath = String(it.mediaPath ?? "");
          const tok = mediaToken(mediaPath, WAZZUP_WEBHOOK_SECRET.value());
          const res = await wazzupSendMedia(WAZZUP_API_KEY.value(), {
            channelId: WAZZUP_CHANNEL_ID.value(),
            chatId,
            chatType: "whatsapp",
            contentUri: `${REGION_HOST}/mediaContent?path=${mediaPath}&t=${tok}`,
            crmMessageId,
          });
          messageId = String(res.messageId ?? crmMessageId);
        } else {
          const res = await wazzupSendText(WAZZUP_API_KEY.value(), {
            channelId: WAZZUP_CHANNEL_ID.value(),
            chatId,
            chatType: "whatsapp",
            text: String(it.text ?? ""),
            crmMessageId,
            refMessageId: (it.refMessageId as string | undefined) || undefined,
          });
          messageId = String(res.messageId ?? crmMessageId);
        }

        await doc.ref.set({ status: "sent", sentAt: ts() }, { merge: true });
        // createdAt = момент реальной отправки: и в чате порядок верный, и
        // дедуп эха вебхука (окно 5 минут) срабатывает.
        await firestore.collection("messages").doc(crmMessageId).set(
          { externalMessageId: messageId, status: "sent", queued: false, createdAt: ts() },
          { merge: true },
        );
        await firestore.collection("conversations").doc(chatId).set(
          { lastMessageAt: ts(), updatedAt: ts() },
          { merge: true },
        );
      } catch (e) {
        const attempts = Number(it.attempts ?? 0) + 1;
        const failed = attempts >= 3;
        await doc.ref.set(
          { attempts, error: String(e instanceof Error ? e.message : e).slice(0, 200), ...(failed ? { status: "failed" } : {}) },
          { merge: true },
        );
        if (failed) {
          await firestore.collection("messages").doc(crmMessageId).set({ status: "failed", queued: false }, { merge: true });
        }
      }
      await sleep(lim.drainGapSec * 1000);
    }
  },
);

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

  const pre = await peekChat(chatId);
  const crmMessageId = randomUUID();

  // Тот же лимит темпа, что и для текста (правило «одинаковый текст» к медиа
  // не применяем — это разные файлы).
  const gate = await gateSend({ authorId: request.auth.uid, chatId, text: `[${type}]`, skipMass: true });
  if (!gate.send) {
    await enqueue({
      kind: "media",
      chatId,
      name: data.name,
      authorId: request.auth.uid,
      mediaPath,
      mediaUrl,
      mediaType: type,
      crmMessageId,
      reason: gate.reason,
    });
    return { ok: true, messageId: crmMessageId, queued: true };
  }

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
    {
      contactId: chatId, phone: chatId, name, chatType: "whatsapp", status: "open", unreadCount: 0,
      lastMessageAt: ts(), lastMessagePreview: `[${type}]`,
      lastOutbound: true, lastAuthorId: request.auth.uid, lastAuthorName: null,
      updatedAt: ts(),
    },
    { merge: true },
  );
  await auditOutbound({
    authorId: request.auth.uid,
    chatId,
    text: `[${type}]`,
    messageId,
    cold: pre.cold,
    flags: gate.flags,
  });
  return { ok: true, messageId, queued: false };
});

/** Редактирование своего сообщения (callable, §16): PATCH Wazzup + Firestore. */
export const editMessage = onCall({ secrets: [WAZZUP_API_KEY] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { messageId?: string; text?: string };
  const messageId = (data.messageId ?? "").trim();
  const text = (data.text ?? "").trim();
  if (!messageId || !text) throw new HttpsError("invalid-argument", "messageId и text обязательны");
  // У сообщений из очереди id документа — наш, в Wazzup нужен externalMessageId.
  const doc = (await db().collection("messages").doc(messageId).get()).data();
  const external = String(doc?.externalMessageId ?? messageId);
  await wazzupEditText(WAZZUP_API_KEY.value(), external, text);
  await db().collection("messages").doc(messageId).set({ text, isEdited: true, updatedAt: ts() }, { merge: true });
  return { ok: true };
});

/** Удаление своего сообщения (callable, §16): DELETE Wazzup + пометка в Firestore. */
export const deleteMessage = onCall({ secrets: [WAZZUP_API_KEY] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { messageId?: string };
  const messageId = (data.messageId ?? "").trim();
  if (!messageId) throw new HttpsError("invalid-argument", "messageId обязателен");
  // Текст читаем ДО удаления — иначе в журнале останется пустое событие.
  const before = (await db().collection("messages").doc(messageId).get()).data();
  // Сообщение ещё в очереди — просто снимаем с отправки.
  if (before?.status === "queued") {
    await db().collection("outbox").doc(messageId).set({ status: "cancelled" }, { merge: true });
    await db().collection("messages").doc(messageId).set(
      { isDeleted: true, text: null, status: "cancelled", queued: false, updatedAt: ts() },
      { merge: true },
    );
    return { ok: true, cancelled: true };
  }
  await wazzupDeleteMessage(WAZZUP_API_KEY.value(), String(before?.externalMessageId ?? messageId));
  await db().collection("messages").doc(messageId).set(
    { isDeleted: true, text: null, mediaUrl: null, contentUri: null, updatedAt: ts() },
    { merge: true },
  );
  await logRisk({
    authorId: request.auth.uid,
    kinds: ["deleted"],
    chatId: String(before?.conversationId ?? ""),
    text: String(before?.text ?? "[медиа]"),
    messageId,
    docId: `del_${messageId}`,
  }).catch(() => {});
  return { ok: true };
});

/**
 * Разбор УЖЕ НАКОПЛЕННОЙ переписки: прогоняет историю сообщений через те же
 * правила и записывает события в riskEvents задним числом (id = bf_<messageId>,
 * повторный запуск ничего не дублирует). Заодно возвращает сводку по дням —
 * видно, в какой день и кто отправлял столько, что WhatsApp мог забанить.
 *
 * GET /riskBackfill?secret=<webhook secret>&days=21[&dry=1]
 */
export const riskBackfill = onRequest(
  { secrets: [WAZZUP_WEBHOOK_SECRET], timeoutSeconds: 540, memory: "1GiB" },
  async (req, res) => {
    if ((req.query.secret as string | undefined) !== WAZZUP_WEBHOOK_SECRET.value()) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    const days = Math.min(Math.max(Number(req.query.days ?? 21), 1), 90);
    const dry = req.query.dry === "1";
    const firestore = db();
    const since = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86400_000);

    type Out = { id: string; chatId: string; authorId: string; text: string; ms: number; broadcast: boolean };
    const outbound: Out[] = [];
    const inboundChats = new Set<string>();
    const perDay = new Map<string, { out: number; inc: number; chats: Set<string>; cold: number; blast: number; hours: Map<number, number> }>();
    let scanned = 0;
    let inboundTotal = 0;

    // Пагинация: читаем только нужные поля.
    let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
    for (let page = 0; page < 40; page++) {
      let q = firestore
        .collection("messages")
        .where("createdAt", ">=", since)
        .orderBy("createdAt", "asc")
        .select("conversationId", "chatId", "direction", "authorId", "text", "createdAt", "isBroadcast", "isAuto", "type")
        .limit(2000);
      if (cursor) q = q.startAfter(cursor);
      const snap = await q.get();
      if (snap.empty) break;
      cursor = snap.docs[snap.docs.length - 1] ?? null;
      scanned += snap.size;

      for (const d of snap.docs) {
        const x = d.data();
        const chatId = String(x.conversationId ?? x.chatId ?? "");
        const ms = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        if (!chatId || !ms) continue;
        const day = dayKey(new Date(ms));
        const bucket = perDay.get(day) ?? { out: 0, inc: 0, chats: new Set<string>(), cold: 0, blast: 0, hours: new Map<number, number>() };
        perDay.set(day, bucket);

        if (x.direction === "inbound") {
          inboundChats.add(chatId);
          inboundTotal++;
          bucket.inc++;
          continue;
        }
        if (x.isAuto === true || x.authorId === "auto") continue;
        bucket.out++;
        bucket.chats.add(chatId);
        const hour = new Date(ms + 5 * 3600_000).getUTCHours();
        bucket.hours.set(hour, (bucket.hours.get(hour) ?? 0) + 1);
        if (x.isBroadcast === true) bucket.blast++;
        outbound.push({
          id: d.id,
          chatId,
          authorId: String(x.authorId ?? ""),
          text: String(x.text ?? (x.type ? `[${x.type}]` : "")),
          ms,
          broadcast: x.isBroadcast === true,
        });
      }
      if (snap.size < 2000) break;
    }

    // Холодные контакты: чат, из которого нам ни разу не писали.
    const chats = [...new Set(outbound.map((o) => o.chatId))].filter((c) => !inboundChats.has(c));
    const coldChats = new Set<string>();
    for (let i = 0; i < chats.length; i += 300) {
      const refs = chats.slice(i, i + 300).map((c) => firestore.doc(`conversations/${c}`));
      const docs = await firestore.getAll(...refs);
      for (const s of docs) {
        if (s.data()?.hasInbound !== true) coldChats.add(s.id);
      }
    }

    // Имена менеджеров.
    const names = new Map<string, string>();
    const users = await firestore.collection("users").get();
    for (const u of users.docs) names.set(u.id, String(u.data().name ?? "").trim());

    const allow = await loadAllowedPhones();
    const state = new Map<string, { c: string; h: string; t: number }[]>();
    const byKind: Record<string, number> = {};
    const byAuthor = new Map<string, Record<string, number>>();
    const events: { id: string; doc: Record<string, unknown>; score: number }[] = [];

    for (const o of outbound) {
      const kinds: RiskKind[] = [];
      const hash = fingerprint(o.text);
      const list = (state.get(o.authorId) ?? []).filter((r) => o.ms - r.t < 60 * 60_000);
      list.push({ c: o.chatId, h: hash, t: o.ms });
      state.set(o.authorId, list.slice(-120));

      if (!o.broadcast) {
        const same = new Set(list.filter((r) => r.h === hash).map((r) => r.c));
        // Как и в живой проверке: короткие ответы рассылкой не считаем.
        if (o.text.trim().length >= 30 && same.size >= 5) kinds.push("mass");
        const burst = new Set(list.filter((r) => o.ms - r.t < 5 * 60_000).map((r) => r.c));
        if (burst.size > 12) kinds.push("burst");
      }
      const cold = coldChats.has(o.chatId);
      if (cold) {
        kinds.push("cold");
        const b = perDay.get(dayKey(new Date(o.ms)));
        if (b) b.cold++;
      }
      kinds.push(...textFlags(o.text, allow, o.chatId));
      if (cold && hasLink(o.text)) kinds.push("link");
      if (isNight(new Date(o.ms))) kinds.push("night");
      if (o.broadcast) kinds.push("blast");

      const weight: Record<string, number> = { card: 3, mass: 3, blast: 2, cold: 2, phone: 2, burst: 2, night: 1, link: 1 };
      const score = kinds.reduce((s, k) => s + (weight[k] ?? 1), 0);
      const notable = kinds.some((k) => (weight[k] ?? 1) >= 2) || kinds.length >= 2;
      if (!notable) continue;

      for (const k of kinds) byKind[k] = (byKind[k] ?? 0) + 1;
      const a = byAuthor.get(o.authorId) ?? {};
      a.total = (a.total ?? 0) + 1;
      for (const k of kinds) a[k] = (a[k] ?? 0) + 1;
      byAuthor.set(o.authorId, a);

      events.push({
        id: `bf_${o.id}`,
        score,
        doc: {
          authorId: o.authorId,
          authorName: names.get(o.authorId) ?? "",
          chatId: o.chatId,
          phone: o.chatId,
          text: o.text.slice(0, 300),
          kinds,
          severity: score >= 3 ? "high" : score >= 2 ? "medium" : "low",
          score,
          count: null,
          messageId: o.id,
          day: dayKey(new Date(o.ms)),
          createdAt: admin.firestore.Timestamp.fromMillis(o.ms),
          backfilled: true,
        },
      });
    }

    if (!dry) {
      for (let i = 0; i < events.length; i += 400) {
        const batch = firestore.batch();
        for (const e of events.slice(i, i + 400)) {
          batch.set(firestore.collection("riskEvents").doc(e.id), e.doc, { merge: true });
        }
        await batch.commit();
      }
    }

    const daysOut = [...perDay.entries()]
      .sort((a, b) => (a[0] < b[0] ? 1 : -1))
      .map(([day, b]) => {
        let peakHour = -1;
        let peak = 0;
        for (const [h, n] of b.hours) if (n > peak) { peak = n; peakHour = h; }
        return {
          day,
          out: b.out,
          in: b.inc,
          chats: b.chats.size,
          cold: b.cold,
          broadcast: b.blast,
          peak: `${peakHour < 0 ? "—" : `${peakHour}:00`} · ${peak}`,
        };
      });

    res.json({
      ok: true,
      days,
      dry,
      scanned,
      outbound: outbound.length,
      inbound: inboundTotal,
      events: events.length,
      byKind,
      byAuthor: [...byAuthor.entries()].map(([uid, v]) => ({ uid, name: names.get(uid) ?? "", ...v })),
      byDay: daysOut,
      top: events
        .sort((a, b) => b.score - a.score)
        .slice(0, 8)
        .map((e) => ({ kinds: e.doc.kinds, name: e.doc.authorName, day: e.doc.day, text: String(e.doc.text).slice(0, 120) })),
    });
  },
);

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
