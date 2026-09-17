import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import { randomUUID } from "crypto";
import { TELEGRAM_BOT_TOKEN } from "./secrets";
import { TgApiError, tgChatAction, tgDeleteMessageApi, tgEditTextApi, tgSendMediaBytes, tgSendTextApi } from "./api";
import { TG_REGION, tgChatIdFromConv, tgMessageIdFromDocId, tgMsgDocId, tgPreview, tgTexts } from "./common";
import { auditOutbound } from "../risk";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * Контроль подозрительной активности для Telegram-отправок.
 *
 * До 2026-08-30 проверялся ТОЛЬКО WhatsApp-путь: менеджер, отправив свой
 * Каспи или чужой номер через Telegram, в журнал контроля не попадал вовсе —
 * «подозрительная активность» на экране аналитики молчала, хотя основной
 * поток переписки идёт именно здесь.
 *
 * Ошибки глотаем: контроль не должен ломать отправку.
 */
async function tgAudit(convId: string, uid: string, text: string, messageId: string): Promise<void> {
  try {
    const c = (await db().doc(`conversations/${convId}`).get()).data() ?? {};
    await auditOutbound({
      authorId: uid,
      // Для правила «чужой номер в тексте» свой номер клиента — это номер из
      // карточки, а не tg-id чата.
      chatId: String(c.phone ?? convId),
      text,
      messageId,
      cold: c.hasInbound !== true,
      // flags не передаём: auditOutbound сам посчитает темп (mass/burst).
    });
  } catch (e) {
    console.error("tgAudit error", e);
  }
}

/** Профиль менеджера users/{uid} — имя нужно для «ответственного».
 *  Экспортирован: WhatsApp-путь (wazzup-functions) использует те же правила. */
export async function callerProfile(uid: string | undefined): Promise<{ uid: string; name: string; role: string }> {
  if (!uid) throw new HttpsError("unauthenticated", "Требуется вход");
  const doc = await db().collection("users").doc(uid).get();
  if (!doc.exists || doc.data()?.isActive === false) {
    throw new HttpsError("permission-denied", "Профиль менеджера не найден или отключён");
  }
  return { uid, name: String(doc.data()?.name ?? "").trim() || "Менеджер", role: String(doc.data()?.role ?? "manager") };
}

/** conversationId → числовой chat_id Telegram (или ошибка). */
function requireTgChatId(conversationId: unknown): { convId: string; chatId: string } {
  const convId = String(conversationId ?? "").trim();
  const chatId = tgChatIdFromConv(convId);
  if (!chatId) throw new HttpsError("invalid-argument", "Это не Telegram-чат");
  return { convId, chatId };
}

/** Клиент заблокировал бота? Проверка до отправки, чтобы не дёргать API зря. */
async function assertOptIn(convId: string): Promise<void> {
  const c = (await db().doc(`contacts/${convId}`).get()).data();
  if (c?.optIn === false) {
    throw new HttpsError("failed-precondition", "Клиент заблокировал бота — сообщение не дойдёт");
  }
}

/** Пометить карточку после 403 от Telegram (клиент заблокировал бота). */
async function markBlocked(convId: string): Promise<void> {
  await db().doc(`contacts/${convId}`).set(
    { optIn: false, optOutAt: ts(), optOutReason: "blocked", updatedAt: ts() },
    { merge: true },
  );
}

/**
 * «Первый ответивший становится ответственным» — атомарно: гонка двух
 * менеджеров разрешается транзакцией, второй увидит чат уже занятым.
 * Экспортирована: работает и для WhatsApp-чатов (convId = цифры номера).
 */
export async function claimIfFree(convId: string, uid: string, name: string): Promise<void> {
  const firestore = db();
  const convRef = firestore.doc(`conversations/${convId}`);
  await firestore.runTransaction(async (tx) => {
    const snap = await tx.get(convRef);
    const current = snap.data()?.responsibleId;
    if (typeof current === "string" && current.length > 0) return; // уже занят
    tx.set(convRef, { responsibleId: uid, responsibleName: name, updatedAt: ts() }, { merge: true });
    tx.set(firestore.doc(`contacts/${convId}`), { responsibleId: uid, responsibleName: name, updatedAt: ts() }, { merge: true });
    tx.set(convRef.collection("history").doc(), { type: "claimed", fromUid: null, toUid: uid, byUid: uid, at: ts() });
  });
}

/**
 * Личный чат владельца: он написал первым человеку, который нам НИКОГДА не
 * писал. Такие переписки не показываются менеджерам в списке чатов (и пуши по
 * ним им не приходят) — владелец ведёт их сам.
 *
 * Метка ставится ОДИН раз, в момент первого исходящего, и больше не
 * снимается: если клиент потом ответит, чат всё равно остаётся личным. Это
 * осознанный выбор — иначе первый же ответ клиента раскрыл бы переписку.
 *
 * Признак «нам никогда не писали» берём запросом по messages, а не по полю
 * hasInbound: оно проставляется лениво (см. risk.ts) и у свежих чатов может
 * отсутствовать — на такой чат нельзя опираться, когда цена ошибки —
 * показать личную переписку всей команде.
 */
export async function markPrivateIfOwnerInitiated(
  convId: string,
  uid: string,
  role: string,
): Promise<void> {
  const isOwner = role === "admin" || role === "administrator";
  if (!isOwner) return;
  const firestore = db();
  try {
    const convRef = firestore.doc(`conversations/${convId}`);
    const conv = (await convRef.get()).data();
    // Уже помечен — второй раз не проверяем (и не снимаем метку).
    if (conv && typeof conv.privateOwnerUid === "string" && conv.privateOwnerUid.length > 0) return;
    // Клиент когда-либо писал — это обычный рабочий чат, не личный.
    if (conv?.hasInbound === true) return;
    const inbound = await firestore
      .collection("messages")
      .where("conversationId", "==", convId)
      .where("direction", "==", "inbound")
      .limit(1)
      .get();
    if (!inbound.empty) return;
    await convRef.set({ privateOwnerUid: uid, updatedAt: ts() }, { merge: true });
  } catch (e) {
    console.error("markPrivateIfOwnerInitiated fail", convId, String(e instanceof Error ? e.message : e));
  }
}

/// Сколько последних ответов менеджера подряд нужно, чтобы перехватить чат.
const TAKEOVER_STREAK = 3;

/**
 * «Кто реально ведёт чат» — по трём последним ответам подряд.
 *
 * claimIfFree назначает ответственного НАВСЕГДА: первый ответивший, и дальше
 * только ручная передача. На практике разговор часто подхватывал другой
 * менеджер, а в карточке продолжал висеть первый — было непонятно, с кого
 * спрашивать. Здесь: если три последних ответа менеджеров подряд написал один
 * человек, он и становится ведущим. Один случайный ответ мимоходом чат не
 * отбирает — нужна серия.
 *
 * Считаются только ответы живых менеджеров: автоответы и ИИ (authorId "auto")
 * пропускаются, иначе бот «уводил» бы чат у человека.
 *
 * Вызывать ПОСЛЕ записи отправленного сообщения — оно должно попасть в счёт.
 */
export async function claimByRecentReplies(convId: string, uid: string, name: string): Promise<void> {
  if (!uid || uid === "auto") return;
  const firestore = db();
  try {
    const snap = await firestore
      .collection("messages")
      .where("conversationId", "==", convId)
      .orderBy("createdAt", "desc")
      .limit(15)
      .get();

    const authors: string[] = [];
    for (const d of snap.docs) {
      const x = d.data();
      if (x.direction !== "outbound") continue;
      if (x.isDeleted === true || x.isInternal === true) continue;
      const author = String(x.authorId ?? "");
      if (!author || author === "auto") continue;
      authors.push(author);
      if (authors.length === TAKEOVER_STREAK) break;
    }
    if (authors.length < TAKEOVER_STREAK) return;
    if (!authors.every((a) => a === uid)) return; // серию прервал кто-то другой

    const convRef = firestore.doc(`conversations/${convId}`);
    await firestore.runTransaction(async (tx) => {
      const cur = (await tx.get(convRef)).data() ?? {};
      const current = typeof cur.responsibleId === "string" && cur.responsibleId.length > 0 ? (cur.responsibleId as string) : null;
      if (current === uid) return; // уже ведёт он
      tx.set(convRef, { responsibleId: uid, responsibleName: name, updatedAt: ts() }, { merge: true });
      tx.set(firestore.doc(`contacts/${convId}`), { responsibleId: uid, responsibleName: name, updatedAt: ts() }, { merge: true });
      tx.set(convRef.collection("history").doc(), { type: "takeover", fromUid: current, toUid: uid, byUid: uid, at: ts() });
    });
  } catch (e) {
    // Не критично: ответственный просто останется прежним.
    console.error("claimByRecentReplies fail", convId, String(e instanceof Error ? e.message : e));
  }
}

/** Записи после успешной отправки: сообщение + диалог + карточка. */
async function writeOutbound(p: {
  convId: string;
  chatId: string;
  tgMessageId: number;
  type: string;
  text: string | null;
  mediaUrl?: string | null;
  fileName?: string | null;
  authorId: string;
  refMessageId?: string | null;
  replyToText?: string | null;
}): Promise<string> {
  const firestore = db();
  const docId = tgMsgDocId(p.chatId, p.tgMessageId);
  await firestore.collection("messages").doc(docId).set(
    {
      conversationId: p.convId,
      chatId: p.convId,
      tgMessageId: p.tgMessageId,
      direction: "outbound",
      type: p.type,
      text: p.text,
      ...(p.mediaUrl ? { mediaUrl: p.mediaUrl } : {}),
      ...(p.fileName ? { fileName: p.fileName } : {}),
      status: "sent",
      authorId: p.authorId,
      ...(p.refMessageId ? { replyToId: p.refMessageId, replyToText: (p.replyToText ?? "").slice(0, 200) } : {}),
      createdAt: ts(),
    },
    { merge: true },
  );
  await firestore.collection("conversations").doc(p.convId).set(
    {
      lastMessageAt: ts(),
      lastMessagePreview: tgPreview(p.type, p.text),
      lastOutbound: true,
      lastAuthorId: p.authorId,
      lastAuthorName: null,
      unreadCount: 0,
      // Менеджер ответил — индикатор «отвечает…» снимаем.
      typing: admin.firestore.FieldValue.delete(),
      updatedAt: ts(),
    },
    { merge: true },
  );
  await firestore.collection("contacts").doc(p.convId).set({ lastMessageAt: ts(), updatedAt: ts() }, { merge: true });
  return docId;
}

/** 429: кладём в tgOutbox и повторяем ровно через retry_after секунд. */
async function enqueueRetry(p: {
  kind: "text" | "media";
  convId: string;
  chatId: string;
  authorId: string;
  retryAfterSec: number;
  text?: string | null;
  refTgMessageId?: number | null;
  replyToText?: string | null;
  mediaPath?: string | null;
  mediaUrl?: string | null;
  mediaType?: string | null;
  fileName?: string | null;
}): Promise<string> {
  const firestore = db();
  const crmId = randomUUID();
  await firestore.collection("tgOutbox").doc(crmId).set({
    kind: p.kind,
    conversationId: p.convId,
    chatId: p.chatId,
    authorId: p.authorId,
    text: p.text ?? null,
    refTgMessageId: p.refTgMessageId ?? null,
    replyToText: p.replyToText ?? null,
    mediaPath: p.mediaPath ?? null,
    mediaUrl: p.mediaUrl ?? null,
    mediaType: p.mediaType ?? null,
    fileName: p.fileName ?? null,
    status: "pending",
    attempts: 0,
    nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + Math.max(1, p.retryAfterSec) * 1000),
    createdAt: ts(),
  });
  const type = p.kind === "media" ? (p.mediaType ?? "document") : "text";
  await firestore.collection("messages").doc(crmId).set({
    conversationId: p.convId,
    chatId: p.convId,
    direction: "outbound",
    type,
    text: p.text ?? null,
    ...(p.mediaUrl ? { mediaUrl: p.mediaUrl } : {}),
    status: "queued",
    queued: true,
    queueReason: "rate",
    authorId: p.authorId,
    crmMessageId: crmId,
    createdAt: ts(),
  });
  await firestore.collection("conversations").doc(p.convId).set(
    {
      lastMessageAt: ts(),
      lastMessagePreview: tgPreview(type, p.text ?? null),
      lastOutbound: true,
      lastAuthorId: p.authorId,
      lastAuthorName: null,
      unreadCount: 0,
      typing: admin.firestore.FieldValue.delete(),
      updatedAt: ts(),
    },
    { merge: true },
  );
  return crmId;
}

/**
 * Отправка текста менеджером (callable). Токен бота — только на сервере.
 * 429 → очередь с повтором ровно через retry_after; 403 → optIn=false.
 */
export const tgSendMessage = onCall({ region: TG_REGION, secrets: [TELEGRAM_BOT_TOKEN] }, async (request) => {
  const me = await callerProfile(request.auth?.uid);
  const d = (request.data ?? {}) as { conversationId?: string; text?: string; refMessageId?: string; replyToText?: string };
  const { convId, chatId } = requireTgChatId(d.conversationId);
  const text = String(d.text ?? "").trim();
  if (!text) throw new HttpsError("invalid-argument", "Пустой текст");
  await assertOptIn(convId);

  const refTg = tgMessageIdFromDocId(d.refMessageId);
  try {
    const sent = await tgSendTextApi(TELEGRAM_BOT_TOKEN.value(), {
      chatId,
      text,
      replyToMessageId: refTg ?? undefined,
    });
    await claimIfFree(convId, me.uid, me.name);
    const messageId = await writeOutbound({
      convId,
      chatId,
      tgMessageId: sent.message_id,
      type: "text",
      text,
      authorId: me.uid,
      refMessageId: d.refMessageId ?? null,
      replyToText: d.replyToText ?? null,
    });
    await claimByRecentReplies(convId, me.uid, me.name);
    await markPrivateIfOwnerInitiated(convId, me.uid, me.role);
    await tgAudit(convId, me.uid, text, messageId);
    return { ok: true, messageId, queued: false };
  } catch (e) {
    if (e instanceof TgApiError && e.code === 429) {
      const crmId = await enqueueRetry({
        kind: "text",
        convId,
        chatId,
        authorId: me.uid,
        retryAfterSec: e.retryAfter ?? 5,
        text,
        refTgMessageId: refTg,
        replyToText: d.replyToText ?? null,
      });
      await claimIfFree(convId, me.uid, me.name);
      return { ok: true, messageId: crmId, queued: true };
    }
    if (e instanceof TgApiError && e.blockedByUser) {
      await markBlocked(convId);
      throw new HttpsError("failed-precondition", "Клиент заблокировал бота — сообщение не дойдёт");
    }
    throw new HttpsError("unavailable", String(e instanceof Error ? e.message : e));
  }
});

/**
 * Отправка файла/фото (callable). Файл уже загружен приложением в наш
 * Storage — берём байты оттуда и шлём в Telegram multipart'ом.
 */
export const tgSendMedia = onCall({ region: TG_REGION, secrets: [TELEGRAM_BOT_TOKEN], memory: "512MiB", timeoutSeconds: 120 }, async (request) => {
  const me = await callerProfile(request.auth?.uid);
  const d = (request.data ?? {}) as {
    conversationId?: string;
    mediaPath?: string;
    mediaUrl?: string;
    type?: string;
    fileName?: string;
  };
  const { convId, chatId } = requireTgChatId(d.conversationId);
  const mediaPath = String(d.mediaPath ?? "").trim();
  if (!mediaPath.startsWith("media/")) throw new HttpsError("invalid-argument", "Некорректный mediaPath");
  const kind = ["image", "video", "audio", "document"].includes(d.type ?? "") ? (d.type as string) : "document";
  const fileName = (d.fileName ?? "").trim() || (mediaPath.split("/").pop() ?? "file");
  await assertOptIn(convId);

  const file = admin.storage().bucket().file(mediaPath);
  let bytes: Buffer;
  let contentType: string | undefined;
  try {
    const [meta] = await file.getMetadata();
    contentType = (meta.contentType as string | undefined) ?? undefined;
    [bytes] = await file.download();
  } catch (e) {
    throw new HttpsError("not-found", `Файл не найден в Storage: ${String(e instanceof Error ? e.message : e)}`);
  }

  try {
    const sent = await tgSendMediaBytes(TELEGRAM_BOT_TOKEN.value(), { chatId, kind, bytes, fileName, contentType });
    await claimIfFree(convId, me.uid, me.name);
    const messageId = await writeOutbound({
      convId,
      chatId,
      tgMessageId: sent.message_id,
      type: kind,
      text: null,
      mediaUrl: d.mediaUrl ?? null,
      fileName,
      authorId: me.uid,
    });
    await claimByRecentReplies(convId, me.uid, me.name);
    await markPrivateIfOwnerInitiated(convId, me.uid, me.role);
    // Медиа: текста нет, но факт «файл холодному контакту ночью» контролю
    // тоже интересен — прогоняем с подписью-типом, как WhatsApp-путь.
    await tgAudit(convId, me.uid, `[${kind}]`, messageId);
    return { ok: true, messageId, queued: false };
  } catch (e) {
    if (e instanceof TgApiError && e.code === 429) {
      const crmId = await enqueueRetry({
        kind: "media",
        convId,
        chatId,
        authorId: me.uid,
        retryAfterSec: e.retryAfter ?? 5,
        mediaPath,
        mediaUrl: d.mediaUrl ?? null,
        mediaType: kind,
        fileName,
      });
      await claimIfFree(convId, me.uid, me.name);
      return { ok: true, messageId: crmId, queued: true };
    }
    if (e instanceof TgApiError && e.blockedByUser) {
      await markBlocked(convId);
      throw new HttpsError("failed-precondition", "Клиент заблокировал бота — сообщение не дойдёт");
    }
    throw new HttpsError("unavailable", String(e instanceof Error ? e.message : e));
  }
});

/**
 * Кнопка «Напишите нам ваш номер» в шапке чата: клиенту уходит просьба
 * прислать номер + reply-кнопка «Поделиться номером». Менеджер, отправивший
 * запрос, становится ответственным (как при обычном ответе).
 */
export const tgRequestPhone = onCall({ region: TG_REGION, secrets: [TELEGRAM_BOT_TOKEN] }, async (request) => {
  const me = await callerProfile(request.auth?.uid);
  const { convId, chatId } = requireTgChatId((request.data ?? {}).conversationId);
  await assertOptIn(convId);
  const texts = await tgTexts();
  try {
    const sent = await tgSendTextApi(TELEGRAM_BOT_TOKEN.value(), {
      chatId,
      text: texts.askPhone,
      replyMarkup: {
        keyboard: [[{ text: texts.shareButton, request_contact: true }]],
        resize_keyboard: true,
        one_time_keyboard: true,
      },
    });
    await claimIfFree(convId, me.uid, me.name);
    const messageId = await writeOutbound({
      convId,
      chatId,
      tgMessageId: sent.message_id,
      type: "text",
      text: texts.askPhone,
      authorId: me.uid,
    });
    await claimByRecentReplies(convId, me.uid, me.name);
    await markPrivateIfOwnerInitiated(convId, me.uid, me.role);
    return { ok: true, messageId };
  } catch (e) {
    if (e instanceof TgApiError && e.blockedByUser) {
      await markBlocked(convId);
      throw new HttpsError("failed-precondition", "Клиент заблокировал бота — сообщение не дойдёт");
    }
    throw new HttpsError("unavailable", String(e instanceof Error ? e.message : e));
  }
});

/** Менеджер открыл чат/печатает → клиент видит «печатает…» (best-effort). */
export const tgTyping = onCall({ region: TG_REGION, secrets: [TELEGRAM_BOT_TOKEN] }, async (request) => {
  await callerProfile(request.auth?.uid);
  const { chatId } = requireTgChatId((request.data ?? {}).conversationId);
  await tgChatAction(TELEGRAM_BOT_TOKEN.value(), chatId).catch(() => {});
  return { ok: true };
});

/**
 * Передача клиента другому менеджеру: смена responsibleId + запись в историю.
 * Разрешено админу, текущему ответственному, либо любому — если чат свободен.
 */
export const tgTransfer = onCall({ region: TG_REGION }, async (request) => {
  const me = await callerProfile(request.auth?.uid);
  const d = (request.data ?? {}) as { conversationId?: string; toUid?: string };
  const { convId } = requireTgChatId(d.conversationId);
  const toUid = String(d.toUid ?? "").trim();
  if (!toUid) throw new HttpsError("invalid-argument", "toUid обязателен");

  const firestore = db();
  const target = await firestore.collection("users").doc(toUid).get();
  if (!target.exists || target.data()?.isActive === false) {
    throw new HttpsError("not-found", "Менеджер не найден или отключён");
  }
  const toName = String(target.data()?.name ?? "").trim() || "Менеджер";

  const convRef = firestore.doc(`conversations/${convId}`);
  const conv = (await convRef.get()).data() ?? {};
  const current = typeof conv.responsibleId === "string" && conv.responsibleId.length > 0 ? (conv.responsibleId as string) : null;
  const isAdmin = me.role === "admin" || me.role === "administrator";
  if (!isAdmin && current !== null && current !== me.uid) {
    throw new HttpsError("permission-denied", "Передать чат может админ или текущий ответственный");
  }

  await convRef.set({ responsibleId: toUid, responsibleName: toName, updatedAt: ts() }, { merge: true });
  await firestore.doc(`contacts/${convId}`).set({ responsibleId: toUid, responsibleName: toName, updatedAt: ts() }, { merge: true });
  await convRef.collection("history").doc().set({
    type: current ? "transferred" : "assigned",
    fromUid: current,
    toUid,
    byUid: me.uid,
    at: ts(),
  });
  return { ok: true };
});

/** Правка нашего исходящего: в Telegram и в Firestore (для очереди — только Firestore). */
export const tgEditMessage = onCall({ region: TG_REGION, secrets: [TELEGRAM_BOT_TOKEN] }, async (request) => {
  await callerProfile(request.auth?.uid);
  const d = (request.data ?? {}) as { conversationId?: string; messageId?: string; text?: string };
  const { chatId } = requireTgChatId(d.conversationId);
  const messageId = String(d.messageId ?? "").trim();
  const text = String(d.text ?? "").trim();
  if (!messageId || !text) throw new HttpsError("invalid-argument", "messageId и text обязательны");

  const firestore = db();
  const ref = firestore.collection("messages").doc(messageId);
  const doc = (await ref.get()).data();
  if (!doc) throw new HttpsError("not-found", "Сообщение не найдено");

  // Ещё в очереди — правим текст будущей отправки без похода в Telegram.
  if (doc.status === "queued") {
    await firestore.collection("tgOutbox").doc(messageId).set({ text }, { merge: true });
    await ref.set({ text, isEdited: true, updatedAt: ts() }, { merge: true });
    return { ok: true };
  }

  const tgMid = (typeof doc.tgMessageId === "number" ? doc.tgMessageId : null) ?? tgMessageIdFromDocId(messageId);
  if (!tgMid) throw new HttpsError("failed-precondition", "У сообщения нет id Telegram");
  try {
    await tgEditTextApi(TELEGRAM_BOT_TOKEN.value(), { chatId, messageId: tgMid, text });
  } catch (e) {
    // Причина в лог — иначе с телефона видно только «ошибка».
    console.error("tgEditMessage fail", JSON.stringify({ messageId, chatId, tgMid, error: String(e instanceof Error ? e.message : e) }));
    throw new HttpsError("unavailable", String(e instanceof Error ? e.message : e));
  }
  await ref.set({ text, isEdited: true, updatedAt: ts() }, { merge: true });
  return { ok: true };
});

/** Удаление нашего исходящего у клиента (Telegram даёт ~48 часов). */
export const tgDeleteMessage = onCall({ region: TG_REGION, secrets: [TELEGRAM_BOT_TOKEN] }, async (request) => {
  await callerProfile(request.auth?.uid);
  const d = (request.data ?? {}) as { conversationId?: string; messageId?: string };
  const { chatId } = requireTgChatId(d.conversationId);
  const messageId = String(d.messageId ?? "").trim();
  if (!messageId) throw new HttpsError("invalid-argument", "messageId обязателен");

  const firestore = db();
  const ref = firestore.collection("messages").doc(messageId);
  const doc = (await ref.get()).data();
  if (!doc) throw new HttpsError("not-found", "Сообщение не найдено");

  // Ещё в очереди — просто снимаем с отправки.
  if (doc.status === "queued") {
    await firestore.collection("tgOutbox").doc(messageId).set({ status: "cancelled" }, { merge: true });
    await ref.set({ isDeleted: true, text: null, status: "cancelled", queued: false, updatedAt: ts() }, { merge: true });
    return { ok: true, cancelled: true };
  }

  const tgMid = (typeof doc.tgMessageId === "number" ? doc.tgMessageId : null) ?? tgMessageIdFromDocId(messageId);
  if (!tgMid) throw new HttpsError("failed-precondition", "У сообщения нет id Telegram");
  try {
    await tgDeleteMessageApi(TELEGRAM_BOT_TOKEN.value(), chatId, tgMid);
  } catch (e) {
    console.error("tgDeleteMessage fail", JSON.stringify({ messageId, chatId, tgMid, error: String(e instanceof Error ? e.message : e) }));
    const msg = e instanceof TgApiError && /can't be deleted/i.test(e.description)
      ? "Telegram не даёт удалить сообщение старше 48 часов"
      : String(e instanceof Error ? e.message : e);
    throw new HttpsError("unavailable", msg);
  }
  await ref.set({ isDeleted: true, text: null, mediaUrl: null, updatedAt: ts() }, { merge: true });
  return { ok: true };
});

/**
 * Досылка очереди tgOutbox (раз в минуту): сообщения, отложенные из-за 429,
 * уходят ровно после nextAttemptAt (retry_after от Telegram). 403 — ретраев
 * нет: клиент заблокировал бота. maxInstances 1 — гонок нет.
 */
export const tgProcessOutbox = onSchedule(
  { region: TG_REGION, schedule: "every 1 minutes", secrets: [TELEGRAM_BOT_TOKEN], timeoutSeconds: 120, maxInstances: 1 },
  async () => {
    const firestore = db();
    const snap = await firestore.collection("tgOutbox").where("status", "==", "pending").limit(50).get();
    if (snap.empty) return;
    const now = Date.now();
    const due = snap.docs
      .filter((d) => ((d.data().nextAttemptAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0) <= now)
      .sort((a, b) => {
        const am = (a.data().createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        const bm = (b.data().createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        return am - bm;
      });

    const startedAt = Date.now();
    for (const doc of due) {
      if (Date.now() - startedAt > 90_000) return;
      const it = doc.data();
      const convId = String(it.conversationId ?? "");
      const chatId = String(it.chatId ?? "");
      const msgRef = firestore.collection("messages").doc(doc.id);
      try {
        let sentId: number;
        if (it.kind === "media") {
          const file = admin.storage().bucket().file(String(it.mediaPath ?? ""));
          const [meta] = await file.getMetadata();
          const [bytes] = await file.download();
          const sent = await tgSendMediaBytes(TELEGRAM_BOT_TOKEN.value(), {
            chatId,
            kind: String(it.mediaType ?? "document"),
            bytes,
            fileName: String(it.fileName ?? "file"),
            contentType: (meta.contentType as string | undefined) ?? undefined,
          });
          sentId = sent.message_id;
        } else {
          const sent = await tgSendTextApi(TELEGRAM_BOT_TOKEN.value(), {
            chatId,
            text: String(it.text ?? ""),
            replyToMessageId: typeof it.refTgMessageId === "number" ? it.refTgMessageId : undefined,
          });
          sentId = sent.message_id;
        }
        await doc.ref.set({ status: "sent", sentAt: ts() }, { merge: true });
        // createdAt = момент реальной отправки — порядок в чате верный.
        await msgRef.set(
          { tgMessageId: sentId, status: "sent", queued: false, createdAt: ts() },
          { merge: true },
        );
        await firestore.collection("conversations").doc(convId).set({ lastMessageAt: ts(), updatedAt: ts() }, { merge: true });
      } catch (e) {
        if (e instanceof TgApiError && e.code === 429) {
          // Снова лимит: ждём ровно retry_after, попыткой не считаем.
          await doc.ref.set(
            { nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + Math.max(1, e.retryAfter ?? 5) * 1000) },
            { merge: true },
          );
          continue;
        }
        if (e instanceof TgApiError && e.blockedByUser) {
          await markBlocked(convId);
          await doc.ref.set({ status: "failed", error: "клиент заблокировал бота" }, { merge: true });
          await msgRef.set({ status: "failed", queued: false, statusError: "Клиент заблокировал бота" }, { merge: true });
          continue;
        }
        const attempts = Number(it.attempts ?? 0) + 1;
        const failed = attempts >= 3;
        await doc.ref.set(
          {
            attempts,
            error: String(e instanceof Error ? e.message : e).slice(0, 200),
            ...(failed
              ? { status: "failed" }
              : { nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + 60_000) }),
          },
          { merge: true },
        );
        if (failed) {
          await msgRef.set(
            { status: "failed", queued: false, statusError: String(e instanceof Error ? e.message : e).slice(0, 200) },
            { merge: true },
          );
        }
      }
      // Лимиты Telegram: ~1 сообщение в секунду в один чат.
      await sleep(400);
    }
  },
);
