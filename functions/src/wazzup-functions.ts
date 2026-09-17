import { onRequest, onCall, HttpsError } from "firebase-functions/v2/https";
import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import { randomUUID, createHmac } from "crypto";
import { normalizeChatId, parseDateMs, wazzupSendText, wazzupSendMedia, wazzupEditText, wazzupDeleteMessage, wazzupChannels, wazzupTemplates, type WazzupMessage, type WazzupStatus } from "./wazzup";
import { auditOutbound, logRisk, peekChat } from "./risk";
import { enqueue, limits, reserveSlot } from "./limits";
import {
  currentChannel,
  isWaba,
  markOpenerSent,
  openerRecentlySent,
  resetChannelCache,
  resetWabaCache,
  templateValues,
  wabaSettings,
  windowOpen,
} from "./waba";
import { publicMediaUrl, toWhatsAppAudio } from "./audio";
import { pushToOfflineManagers } from "./push";
import { ANTHROPIC_API_KEY, maybeAiSuggest } from "./ai-reply";
import { maybeTrainingReply } from "./training-reply";
import { detectBookingIntent } from "./booking-intent";
import { detectPaymentIntent, maybePaymentAlert } from "./payment-alert";
import { TELEGRAM_BOT_TOKEN } from "./telegram/secrets";
import { detectTopic, isOwnTabTopic } from "./topics";
import { exactFingerprint, makeVariants, pickQuickReplyVariant, textRepeats, uniquifyText } from "./variate";
import { autoReplyStillNeeded, maybeWaAutoReply } from "./wa-autoreply";
import { callerProfile, claimByRecentReplies, claimIfFree, markPrivateIfOwnerInitiated } from "./telegram/outbound";
import { WAZZUP_API_KEY, WAZZUP_CHANNEL_ID, WAZZUP_WEBHOOK_SECRET } from "./wazzup-secrets";

/**
 * WhatsApp через Wazzup — ВТОРОЙ транспорт рядом с Telegram (вернулся из
 * архива 2026-08-06). Ключи чатов — цифры номера (как раньше), Telegram —
 * tg_<id>: приложение маршрутизирует по префиксу.
 *
 * Отличие от старой версии: отправка менеджера ВСЕГДА идёт через очередь
 * outbox с «человечной» задержкой (config/wazzup.sendDelaySec, по умолчанию
 * 15 сек) — в чате сообщение видно сразу, в WhatsApp уходит чуть позже
 * ровным темпом (анти-бан). Реальную отправку делает processOutbox.
 */

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

const REGION_HOST = "https://europe-west1-vip-client-manager.cloudfunctions.net";

/** Подпись пути медиа (чтобы mediaContent не отдавал произвольные файлы). */
function mediaToken(path: string, secret: string): string {
  return createHmac("sha256", secret).update(path).digest("hex");
}

/** Имя файла из пути в Storage — оно уходит в ссылку и в Content-Disposition. */
function mediaFileName(path: string): string {
  const base = path.split("/").pop() ?? "file";
  return base.includes(".") ? base : `${base}.bin`;
}

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
 * Задержка «человечной» отправки WhatsApp, сек. СЛУЧАЙНАЯ в диапазоне
 * config/wazzup.sendDelayMinSec…sendDelayMaxSec (по умолчанию 10–40):
 * одинаковый ритм отправок сам по себе выдаёт автоматику.
 */
async function waSendDelaySec(): Promise<number> {
  let min = 15;
  let max = 40;
  try {
    const d = (await db().doc("config/wazzup").get()).data() ?? {};
    const a = Number(d.sendDelayMinSec);
    const b = Number(d.sendDelayMaxSec);
    if (Number.isFinite(a) && a >= 0) min = Math.min(a, 600);
    if (Number.isFinite(b) && b >= 0) max = Math.min(b, 600);
    if (max < min) max = min;
  } catch {
    /* значения по умолчанию */
  }
  return Math.round(min + Math.random() * (max - min));
}

/**
 * Публичная выдача медиа для Wazzup: стримит файл из Storage с чистыми
 * заголовками, т.к. прямую ссылку firebasestorage Wazzup не принимает.
 */
export const mediaContent = onRequest({ secrets: [WAZZUP_WEBHOOK_SECRET] }, async (req, res) => {
  const path = String(req.query.path ?? "");
  const t = String(req.query.t ?? "");
  if (!path.startsWith("media/") || t !== mediaToken(path, WAZZUP_WEBHOOK_SECRET.value())) {
    // Логируем отказ: если загрузчик Wazzup обрезает параметры ссылки, мы
    // отдаём 401 и мессенджер считает вложение битым — без этой строки
    // причину не увидеть.
    console.error("mediaContent 401", JSON.stringify({
      url: req.originalUrl.slice(0, 200),
      method: req.method,
      ua: (req.get("user-agent") ?? "").slice(0, 80),
    }));
    res.status(401).send("unauthorized");
    return;
  }
  try {
    const file = admin.storage().bucket().file(path);
    const [meta] = await file.getMetadata();
    const [buf] = await file.download();
    const type = (meta.contentType as string) ?? "application/octet-stream";
    res.set("Content-Type", type);
    res.set("Cache-Control", "public, max-age=3600");
    res.set("Accept-Ranges", "bytes");
    // Имя файла с расширением: по ссылке без него Meta не определяла тип и
    // отбивала голосовые («тип не поддерживается мессенджером»).
    res.set("Content-Disposition", `inline; filename="${mediaFileName(path)}"`);

    // Докачка по кускам. Раньше заголовок Accept-Ranges был, а Range мы
    // игнорировали и всегда отвечали 200 — строгий загрузчик считает такой
    // ответ битым.
    const range = req.get("range");
    const m = range ? /^bytes=(\d*)-(\d*)$/.exec(range.trim()) : null;
    let status = 200;
    let body = buf;
    if (m) {
      const start = m[1] ? Number(m[1]) : 0;
      const end = m[2] ? Math.min(Number(m[2]), buf.length - 1) : buf.length - 1;
      if (Number.isFinite(start) && start <= end && start < buf.length) {
        body = buf.subarray(start, end + 1);
        res.set("Content-Range", `bytes ${start}-${end}/${buf.length}`);
        status = 206;
      }
    }
    res.set("Content-Length", String(body.length));
    // Диагностика: видно, кто и как забирает файл (Wazzup/Meta) и что мы
    // ответили — без этого причина отказа мессенджера не читается.
    console.log("mediaContent", JSON.stringify({
      path,
      type,
      method: req.method,
      status,
      bytes: body.length,
      total: buf.length,
      range: range ?? null,
      ua: (req.get("user-agent") ?? "").slice(0, 80),
    }));
    if (req.method === "HEAD") {
      res.status(status).end();
      return;
    }
    res.status(status).send(body);
  } catch (e) {
    console.error("mediaContent error", path, e);
    res.status(404).send("not found");
  }
});

/**
 * Приём вебхуков Wazzup → Firestore. Модель: contacts/{chatId},
 * conversations/{chatId}, messages/{messageId} (ключ = messageId → дедуп).
 */
export const wazzupWebhook = onRequest(
  // TELEGRAM_BOT_TOKEN — сигнал «клиент готов оплатить» уходит руководителю в
  // Telegram, даже когда сам разговор идёт в WhatsApp.
  { secrets: [WAZZUP_WEBHOOK_SECRET, WAZZUP_API_KEY, WAZZUP_CHANNEL_ID, ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN] },
  async (req, res) => {
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
  /** Чат → текст, в котором клиент заявил о готовности платить. */
  const payReady = new Map<string, string>();
  const pushItems: { chatId: string; title: string; body: string }[] = [];

  try {
    for (const m of messages) {
      const chatType = m.chatType ?? "whatsapp";
      const chatId = normalizeChatId(chatType, String(m.chatId ?? ""));
      if (!chatId || !m.messageId) continue;

      const inbound = !m.isEcho;
      const type = m.type ?? "text";
      const echoError =
        !inbound && m.status === "error"
          ? String(typeof m.error === "string" ? m.error : m.error ? JSON.stringify(m.error) : "нет описания").slice(0, 300)
          : null;
      if (echoError) console.error("wazzup echo error raw", JSON.stringify(m));
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

      batch.set(
        firestore.collection("contacts").doc(chatId),
        { phone: chatId, name: `+${chatId}`, chatType, channelId: m.channelId ?? null, lastMessageAt: createdAt, updatedAt: ts() },
        { merge: true },
      );

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
      if (inbound) {
        conv.lastAuthorId = null;
        conv.lastAuthorName = null;
        conv.unreadCount = admin.firestore.FieldValue.increment(1);
        conv.hasInbound = true;
        conv.lastInboundAt = createdAt;
        // Тема обращения — по ключевым словам входящего. Раздел, выбранный
        // менеджером руками (topicLocked), словами не перетирается.
        const topic = await detectTopic(text ?? "");
        const cur = (await firestore.doc(`conversations/${chatId}`).get()).data();
        let effectiveTopic = cur?.topic as string | undefined;
        if (topic && cur?.topicLocked !== true) {
          conv.topic = topic;
          effectiveTopic = topic;
        }
        // «Хочет записаться» — метка временная (см. FsConversation.wantsAppointment
        // на клиенте): держим момент последнего такого сообщения, а не факт
        // «было хоть раз». Новое обращение освежает срок сама по себе.
        // Обучение/БАДы пропускаем: «когда можно записаться на обучение» —
        // это не про запись на приём к врачу, у темы свой сценарий.
        if (!isOwnTabTopic(effectiveTopic) && detectBookingIntent(text ?? "")) {
          conv.wantsAppointmentAt = createdAt;
        }
        // «Готов оплатить» — сигнал уходит после коммита (ниже), здесь только
        // запоминаем текст: тема чата к этому моменту ещё не записана.
        if (detectPaymentIntent(text ?? "")) payReady.set(chatId, text ?? "");
      }
      // Авторство исходящего решается ПОСЛЕ поиска twin (ниже): эхо нашего
      // же сообщения не должно перетирать менеджера, записанного при отправке.

      // Эхо нашего исходящего приходит с ДРУГИМ messageId — ищем уже
      // записанное нами сообщение (у него есть crmMessageId) и дополняем его,
      // иначе в чате появляется дубль.
      //
      // Текст сравниваем НОРМАЛИЗОВАННЫМ: WhatsApp обрезает хвостовые пробелы
      // и может схлопнуть переносы, поэтому точное сравнение подводило.
      // Медиа-эхо приходит вообще без текста — его сопоставляем по типу.
      let twinRef: FirebaseFirestore.DocumentReference | null = null;
      let twinIsAuto = false;
      if (!inbound) {
        const nowMs = ms ?? Date.now();
        const norm = (s: string) => s.replace(/\s+/g, " ").trim();
        const echoText = norm(text ?? "");
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
          // Уже сопоставлено с другим эхом — не забираем повторно.
          if (x.echoMessageId) continue;
          const tms = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          if (Math.abs(tms - nowMs) > 5 * 60000) continue;
          const ourText = norm(String(x.text ?? ""));
          const same = echoText.length > 0 ? ourText === echoText : String(x.type ?? "") === type;
          if (!same) continue;
          twinRef = d.ref;
          twinIsAuto = x.authorId === "auto";
          break;
        }
      }

      // Кто «ответил последним» в списке чатов. Эхо НАШЕГО сообщения (нашёлся
      // twin) автора не трогает: менеджер уже записан в момент отправки, а в
      // эхе Wazzup всегда имя аккаунта («Admin») — из-за этого весь список
      // показывал «ответил Admin». Имя из эха пишем только для сообщений,
      // реально отправленных мимо CRM (из интерфейса Wazzup).
      if (!inbound && !twinRef) {
        conv.lastAuthorId = null;
        conv.lastAuthorName = m.authorName ?? null;
      }
      // Эхо автосообщения (автоответ/догрев) чат в списке не поднимает.
      if (twinIsAuto) {
        delete conv.lastMessageAt;
        delete conv.lastMessagePreview;
        delete conv.lastOutbound;
      }
      batch.set(firestore.collection("conversations").doc(chatId), conv, { merge: true });

      if (twinRef) {
        batch.set(
          twinRef,
          {
            externalMessageId: m.messageId,
            status: m.status ?? "sent",
            echoMessageId: m.messageId,
            ...(echoError ? { statusError: echoError } : {}),
          },
          { merge: true },
        );
      } else {
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
            ...(echoError ? { statusError: echoError } : {}),
            authorName: m.authorName ?? null,
            createdAt,
          },
          { merge: true },
        );
      }

      await batch.commit();
    }

    // Статусы доставки/прочтения: обновляем только существующие документы.
    for (const s of statuses) {
      if (!s.messageId || !s.status) continue;
      const reason =
        s.status === "error"
          ? String(
              s.errorDescription ??
                s.description ??
                (typeof s.error === "string" ? s.error : s.error ? JSON.stringify(s.error) : ""),
            ).slice(0, 300)
          : null;
      if (s.status === "error") console.error("wazzup status error raw", JSON.stringify(s));
      const patch = { status: s.status, statusAt: ts(), ...(reason ? { statusError: reason } : {}) };

      const ref = firestore.collection("messages").doc(String(s.messageId));
      const snap = await ref.get();
      if (snap.exists) {
        await ref.set(patch, { merge: true });
        continue;
      }
      const found = await firestore
        .collection("messages")
        .where("externalMessageId", "==", String(s.messageId))
        .limit(1)
        .get();
      if (!found.empty) {
        await found.docs[0]!.ref.set(patch, { merge: true });
      }
    }

    // Автоответ на ПЕРВОЕ обращение клиента (2026-08-10, заменил автоответ
    // Wazzup, который уходил шаблоном и съедал лимит 250). Один раз на чат
    // за всё время, обычным текстом в открытом окне.
    for (const cid of inboundChats) {
      try {
        await maybeWaAutoReply(cid);
      } catch (e) {
        console.error("waAutoReply error", e);
      }
      // Черновик ответа для менеджера (если включён в настройках) — не
      // мешает автоответу выше, просто добавляет подсказку в тот же чат.
      try {
        await maybeAiSuggest(cid);
      } catch (e) {
        console.error("aiReply wa error", e);
      }
      // Ученики — свой сценарий на текстах раздела «Обучение» (внутри стоит
      // проверка темы, пациентов этот вызов не трогает).
      try {
        await maybeTrainingReply(cid);
      } catch (e) {
        console.error("trainingReply wa error", e);
      }
      // Клиент готов платить — отдельный сигнал руководителю в Telegram,
      // чтобы выставить счёт (обычный пуш о входящем теряется в потоке).
      const payText = payReady.get(cid);
      if (payText !== undefined) {
        try {
          await maybePaymentAlert(cid, payText, TELEGRAM_BOT_TOKEN.value());
        } catch (e) {
          console.error("paymentAlert wa error", e);
        }
      }
    }

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



/**
 * Отправка одобренного Meta шаблона прямо сейчас (WABA «первое касание»):
 * зовёт клиента в чат, когда 24-часовое окно закрыто. Пишется в переписку
 * отдельной строкой, чтобы менеджер видел, что приглашение ушло.
 */
async function sendTemplateNow(p: {
  apiKey: string;
  channelId: string;
  chatId: string;
  templateId: string;
  values: string[];
  authorId: string;
}): Promise<void> {
  const crmMessageId = randomUUID();
  const res = await wazzupSendText(p.apiKey, {
    channelId: p.channelId,
    chatId: p.chatId,
    chatType: "whatsapp",
    text: "",
    crmMessageId,
    templateId: p.templateId,
    templateValues: p.values,
  });
  const messageId = String(res.messageId ?? crmMessageId);
  await db().collection("messages").doc(messageId).set(
    {
      conversationId: p.chatId,
      chatId: p.chatId,
      externalMessageId: res.messageId ?? null,
      direction: "outbound",
      type: "text",
      text: "📨 Приглашение в чат (шаблон WhatsApp Business)",
      status: "sent",
      authorId: p.authorId,
      isTemplate: true,
      crmMessageId,
      createdAt: ts(),
    },
    { merge: true },
  );
}

/**
 * Отправка текста WhatsApp: сообщение пишется в чат СРАЗУ (менеджер видит
 * мгновенно, статус «отправляется…»), а клиенту уходит через outbox.
 *
 * QR-канал: с «человечной» задержкой waSendDelaySec — анти-бан.
 * WABA: задержка не нужна (официальный API, банов за темп нет), но вне
 * 24-часового окна свободный текст Meta не пропустит — текст ждёт ответа
 * клиента в очереди, а клиента зовём одобренным шаблоном.
 */
async function sendOutboundText(p: {
  apiKey: string;
  channelId: string;
  phone: string;
  text: string;
  name?: string;
  authorId: string;
  refMessageId?: string;
  replyToText?: string;
  /** Менеджер подтвердил отправку приглашения шаблоном (окно закрыто). */
  sendOpener?: boolean;
}): Promise<{ messageId: string; queued: boolean; waitWindow?: boolean }> {
  const chatId = normalizeChatId("whatsapp", p.phone);
  const original = p.text.trim();
  if (!chatId || !original) throw new Error("phone и text обязательны");

  // Одинаковые сообщения многим = бан номера. Защита в два слоя:
  //  1) быстрый ответ — берём один из 5–6 готовых вариантов (хранятся на
  //     сервере рядом с шаблоном, менеджер их не видит и не правит);
  //  2) любой другой повторяющийся текст — лёгкая автоуникализация.
  // Первому получателю текст уходит ровно как написан.
  const repeats = await textRepeats(original, chatId);
  const variant = await pickQuickReplyVariant(original);
  const text = variant ?? (repeats ? uniquifyText(original, chatId) : original);
  const varied = text !== original;

  const pre = await peekChat(chatId);
  const crmMessageId = randomUUID();
  const ch = await currentChannel(p.apiKey, p.channelId);
  const waba = isWaba(ch.transport);
  const sendChannelId = ch.channelId || p.channelId;

  // WABA вне окна: свободный текст Meta не пропустит. Автоматически ничего
  // не шлём (решение владельца 2026-08-09) — возвращаем WINDOW_CLOSED, и
  // приложение спрашивает менеджера. С подтверждением (sendOpener) текст
  // ложится в очередь до ответа клиента, а клиента зовём шаблоном.
  if (waba && !(await windowOpen(chatId))) {
    const st = await wabaSettings();
    if (!st.openerTemplateId) {
      throw new Error(
        "WABA: клиент не писал больше 24 часов — свободный текст не уйдёт. " +
          "Выберите шаблон приглашения в настройках канала.",
      );
    }
    if (!p.sendOpener) throw new Error("WINDOW_CLOSED");
    await enqueue({
      kind: "text",
      chatId,
      text,
      name: p.name,
      authorId: p.authorId,
      refMessageId: p.refMessageId,
      replyToText: p.replyToText,
      crmMessageId,
      reason: "window",
      waitWindow: true,
    });
    // Приглашение — не чаще раза в openerCooldownHours на чат.
    if (!(await openerRecentlySent(chatId, st.openerCooldownHours))) {
      await sendTemplateNow({
        apiKey: p.apiKey,
        channelId: sendChannelId,
        chatId,
        templateId: st.openerTemplateId,
        values: templateValues(st.openerVars, { name: p.name, text }),
        authorId: p.authorId,
      });
      await markOpenerSent(chatId);
    }
    return { messageId: crmMessageId, queued: true, waitWindow: true };
  }

  const delay = waba ? 0 : await waSendDelaySec();
  await enqueue({
    kind: "text",
    chatId,
    text,
    name: p.name,
    authorId: p.authorId,
    refMessageId: p.refMessageId,
    replyToText: p.replyToText,
    crmMessageId,
    reason: "delay",
    nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + delay * 1000),
  });
  // Метка «текст уникализирован» — чтобы в чате было видно, почему
  // отправленное чуть отличается от сохранённого шаблона.
  if (varied) {
    await db().collection("messages").doc(crmMessageId).set({ textVaried: true }, { merge: true });
  }

  // flags НЕ передаём: пустой массив выглядел для auditOutbound как «темп
  // уже посчитан, нарушений нет» — и правила «один текст многим» / «слишком
  // быстро» не срабатывали никогда.
  await auditOutbound({ authorId: p.authorId, chatId, text, messageId: crmMessageId, cold: pre.cold }).catch(() => {});
  return { messageId: crmMessageId, queued: true };
}

/** Отправка текста менеджером (callable) + захват ответственного. */
export const sendMessage = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (request) => {
  const me = await callerProfile(request.auth?.uid);
  const data = (request.data ?? {}) as { phone?: string; text?: string; name?: string; refMessageId?: string; replyToText?: string; sendOpener?: boolean };
  try {
    const res = await sendOutboundText({
      apiKey: WAZZUP_API_KEY.value(),
      channelId: WAZZUP_CHANNEL_ID.value(),
      phone: String(data.phone ?? ""),
      text: data.text ?? "",
      name: data.name,
      authorId: me.uid,
      refMessageId: (data.refMessageId ?? "").trim() || undefined,
      replyToText: data.replyToText,
      sendOpener: data.sendOpener === true,
    });
    const chatId = normalizeChatId("whatsapp", String(data.phone ?? ""));
    if (chatId) {
      await claimIfFree(chatId, me.uid, me.name);
      await claimByRecentReplies(chatId, me.uid, me.name);
      await markPrivateIfOwnerInitiated(chatId, me.uid, me.role);
    }
    return { ok: true, messageId: res.messageId, queued: res.queued, waitWindow: res.waitWindow === true };
  } catch (e) {
    const msg = String(e instanceof Error ? e.message : e);
    // Окно закрыто — приложение спросит менеджера и повторит с sendOpener.
    if (msg === "WINDOW_CLOSED") throw new HttpsError("failed-precondition", "WINDOW_CLOSED");
    throw new HttpsError("invalid-argument", msg);
  }
});

/** Отправка медиа менеджером (callable): тоже через очередь с задержкой. */
export const sendMedia = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (request) => {
  const me = await callerProfile(request.auth?.uid);
  const data = (request.data ?? {}) as { phone?: string; mediaPath?: string; mediaUrl?: string; type?: string; name?: string; sendOpener?: boolean };
  const chatId = normalizeChatId("whatsapp", String(data.phone ?? ""));
  const mediaPath = (data.mediaPath ?? "").trim();
  const mediaUrl = (data.mediaUrl ?? "").trim();
  if (!chatId || !mediaPath) throw new HttpsError("invalid-argument", "phone и mediaPath обязательны");
  const type = data.type ?? "document";

  const pre = await peekChat(chatId);
  const crmMessageId = randomUUID();
  const ch = await currentChannel(WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value());
  const waba = isWaba(ch.transport);

  // WABA вне окна: без подтверждения менеджера ничего не отправляем.
  if (waba && !(await windowOpen(chatId))) {
    const st = await wabaSettings();
    if (!st.openerTemplateId) {
      throw new HttpsError(
        "failed-precondition",
        "WABA: клиент не писал больше 24 часов. Выберите шаблон приглашения в настройках канала.",
      );
    }
    if (data.sendOpener !== true) throw new HttpsError("failed-precondition", "WINDOW_CLOSED");
    await enqueue({
      kind: "media",
      chatId,
      name: data.name,
      authorId: me.uid,
      mediaPath,
      mediaUrl,
      mediaType: type,
      crmMessageId,
      reason: "window",
      waitWindow: true,
    });
    if (st.openerTemplateId && !(await openerRecentlySent(chatId, st.openerCooldownHours))) {
      await sendTemplateNow({
        apiKey: WAZZUP_API_KEY.value(),
        channelId: ch.channelId || WAZZUP_CHANNEL_ID.value(),
        chatId,
        templateId: st.openerTemplateId,
        values: templateValues(st.openerVars, { name: data.name, text: `[${type}]` }),
        authorId: me.uid,
      });
      await markOpenerSent(chatId);
    }
    await claimIfFree(chatId, me.uid, me.name);
    await claimByRecentReplies(chatId, me.uid, me.name);
    await markPrivateIfOwnerInitiated(chatId, me.uid, me.role);
    return { ok: true, messageId: crmMessageId, queued: true, waitWindow: true };
  }

  const delay = waba ? 0 : await waSendDelaySec();
  await enqueue({
    kind: "media",
    chatId,
    name: data.name,
    authorId: me.uid,
    mediaPath,
    mediaUrl,
    mediaType: type,
    crmMessageId,
    reason: "delay",
    nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + delay * 1000),
  });
  await claimIfFree(chatId, me.uid, me.name);
  await claimByRecentReplies(chatId, me.uid, me.name);
  await markPrivateIfOwnerInitiated(chatId, me.uid, me.role);
  await auditOutbound({ authorId: me.uid, chatId, text: `[${type}]`, messageId: crmMessageId, cold: pre.cold }).catch(() => {});
  return { ok: true, messageId: crmMessageId, queued: true };
});

/**
 * Занять сообщение под отправку: pending → sending (транзакция). Нужна,
 * потому что очередь разбирают ДВА обработчика — мгновенный триггер
 * onOutboxCreated и планировщик processOutbox. Без claim одно сообщение
 * могло уйти клиенту дважды.
 */
async function claimOutbox(ref: FirebaseFirestore.DocumentReference): Promise<boolean> {
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.data()?.status !== "pending") return false;
    tx.set(ref, { status: "sending", claimedAt: ts() }, { merge: true });
    return true;
  });
}

/** Реальная отправка одного элемента очереди в Wazzup + записи в чат. */
async function deliverOutbox(
  ref: FirebaseFirestore.DocumentReference,
  it: Record<string, unknown>,
  channelId: string,
): Promise<void> {
  const firestore = db();
  const chatId = String(it.chatId ?? "");
  const crmMessageId = String(it.crmMessageId ?? ref.id);
  try {
    let messageId = crmMessageId;
    if (it.kind === "media") {
      let mediaPath = String(it.mediaPath ?? "");
      // Голосовое: канал WABA принимает MP3 (так же его шлёт и сам интерфейс
      // Wazzup — «wazzup_audio.mp3»), а записанный на телефоне M4A и даже
      // ogg/opus Meta отбивала. Результат конвертации запоминаем — повтор из
      // очереди не гоняет ffmpeg заново.
      if (String(it.mediaType ?? "") === "audio") {
        const conv = String(it.mediaPathAudio ?? "") || (await toWhatsAppAudio(mediaPath));
        if (conv) {
          mediaPath = conv;
          if (!it.mediaPathAudio) await ref.set({ mediaPathAudio: conv }, { merge: true });
        }
      }
      // Прямая ссылка на файл в Storage; наш mediaContent — только запасной
      // вариант (через него Meta отбивала вложения с WRONG_CONTENT, хотя из
      // интерфейса Wazzup тот же файл уходил нормально).
      const tok = mediaToken(mediaPath, WAZZUP_WEBHOOK_SECRET.value());
      const direct = await publicMediaUrl(mediaPath);
      const contentUri =
        direct ?? `${REGION_HOST}/mediaContent/${encodeURIComponent(mediaFileName(mediaPath))}?path=${mediaPath}&t=${tok}`;
      console.log("deliverOutbox media", JSON.stringify({
        crmMessageId, chatId, mediaType: it.mediaType ?? null, mediaPath, direct: Boolean(direct),
      }));
      const res = await wazzupSendMedia(WAZZUP_API_KEY.value(), {
        channelId,
        chatId,
        chatType: "whatsapp",
        contentUri,
        crmMessageId,
      });
      messageId = String(res.messageId ?? crmMessageId);
    } else if (it.kind === "template") {
      // Одобренный Meta шаблон: единственный способ написать первым.
      const res = await wazzupSendText(WAZZUP_API_KEY.value(), {
        channelId,
        chatId,
        chatType: "whatsapp",
        text: "",
        crmMessageId,
        templateId: String(it.templateId ?? ""),
        templateValues: ((it.templateValues ?? []) as unknown[]).map(String),
      });
      messageId = String(res.messageId ?? crmMessageId);
      await markOpenerSent(chatId);
    } else {
      const res = await wazzupSendText(WAZZUP_API_KEY.value(), {
        channelId,
        chatId,
        chatType: "whatsapp",
        text: String(it.text ?? ""),
        crmMessageId,
        refMessageId: (it.refMessageId as string | undefined) || undefined,
      });
      messageId = String(res.messageId ?? crmMessageId);
    }

    await ref.set({ status: "sent", sentAt: ts() }, { merge: true });
    // createdAt = момент реальной отправки: порядок в чате верный и дедуп
    // эха вебхука (окно 5 минут) срабатывает.
    await firestore.collection("messages").doc(crmMessageId).set(
      { externalMessageId: messageId, status: "sent", queued: false, createdAt: ts() },
      { merge: true },
    );
    // Автосообщения (authorId 'auto') не двигают чат в списке.
    await firestore.collection("conversations").doc(chatId).set(
      { ...(it.authorId === "auto" ? {} : { lastMessageAt: ts() }), updatedAt: ts() },
      { merge: true },
    );
  } catch (e) {
    const attempts = Number(it.attempts ?? 0) + 1;
    const failed = attempts >= 3;
    await ref.set(
      {
        attempts,
        error: String(e instanceof Error ? e.message : e).slice(0, 200),
        // Не «sent» — возвращаем в очередь, чтобы планировщик повторил.
        status: failed ? "failed" : "pending",
      },
      { merge: true },
    );
    if (failed) {
      await firestore.collection("messages").doc(crmMessageId).set(
        { status: "failed", queued: false, statusError: String(e instanceof Error ? e.message : e).slice(0, 200) },
        { merge: true },
      );
    }
  }
}

/**
 * Мгновенный обработчик очереди: срабатывает на создание записи в outbox,
 * выдерживает «человечную» задержку и отправляет. Благодаря ему пауза равна
 * ровно sendDelaySec, а не «до следующей минуты» (планировщик остаётся
 * страховкой для повторов и накопившегося).
 */
export const onOutboxCreated = onDocumentCreated(
  // maxInstances выше общего (5): каждый обработчик ЖДЁТ «человечную»
  // задержку 15–40 с, и три менеджера, написавшие подряд, занимали все
  // слоты — четвёртое сообщение получало «no available instance» и ждало
  // планировщик. CPU дробный, как у остальных, — квоту это не трогает.
  { document: "outbox/{id}", secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID, WAZZUP_WEBHOOK_SECRET], timeoutSeconds: 120, maxInstances: 12 },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const it = snap.data() as Record<string, unknown>;
    if (it.status !== "pending") return;
    // Ждущие 24-часового окна WABA разбирает только планировщик.
    if (it.waitWindow === true) return;

    // Рассылка ставит десятки сообщений с отправкой через 5–40 минут. Раньше
    // каждое такое занимало слот на 90 с (спало до предела), и 95 писем волны
    // 06.09 вытеснили менеджеров на 20 минут. Далёкие по времени — только
    // планировщику; триггер держит слот лишь ради ближайшей минуты.
    const dueAt = (it.nextAttemptAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? Date.now();
    if (dueAt - Date.now() > 60_000) return;

    // Повтор доставки события для уже снятого из очереди (stopqueue) или
    // отправленного планировщиком — выходим сразу, не занимая слот сном.
    const cur = await snap.ref.get();
    if (!cur.exists || cur.data()?.status !== "pending") return;

    const wait = Math.min(Math.max(dueAt - Date.now(), 0), 60_000);
    if (wait > 0) await sleep(wait);

    // Автоответ отменяется, если менеджер за эти секунды ответил сам.
    if (it.autoReply === true) {
      const createdAt = (it.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? Date.now();
      if (!(await autoReplyStillNeeded(String(it.chatId ?? ""), createdAt))) {
        await snap.ref.set({ status: "cancelled", reason: "менеджер ответил сам" }, { merge: true });
        await db()
          .collection("messages")
          .doc(String(it.crmMessageId ?? snap.id))
          .delete()
          .catch(() => {});
        return;
      }
    }

    // Отменили или уже отправлено другим обработчиком — выходим.
    if (!(await claimOutbox(snap.ref))) return;
    const slot = await reserveSlot();
    if (!slot.allow) {
      // Лимит канала исчерпан — вернём в очередь, дошлёт планировщик.
      await snap.ref.set({ status: "pending" }, { merge: true });
      return;
    }
    const ch = await currentChannel(WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value());
    const fresh = (await snap.ref.get()).data() as Record<string, unknown>;
    await deliverOutbox(snap.ref, fresh, ch.channelId || WAZZUP_CHANNEL_ID.value());
  },
);

/**
 * Досылка очереди: раз в минуту отправляет накопившееся ровным темпом.
 * Сообщения с nextAttemptAt в будущем («человечная» задержка) пропускаются.
 */
export const processOutbox = onSchedule(
  { schedule: "every 1 minutes", secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID, WAZZUP_WEBHOOK_SECRET], timeoutSeconds: 120, maxInstances: 1 },
  async () => {
    const firestore = db();
    const lim = await limits();
    const outCh = await currentChannel(WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value());
    // Берём широко, а не первые 30 по времени создания: во время рассылки
    // первые 30 — это её письма с отправкой «через полчаса», и сообщение
    // менеджера, созданное позже, в выборку не попадало вовсе, пока волна
    // не уйдёт. Сначала — живые сообщения менеджеров, затем автосообщения.
    const snap = await firestore
      .collection("outbox")
      .where("status", "==", "pending")
      .orderBy("createdAt", "asc")
      .limit(300)
      .get();
    if (snap.empty) return;

    // Зависшие в «sending» (обработчик умер на полпути) — вернуть в очередь.
    const stuck = await firestore.collection("outbox").where("status", "==", "sending").limit(20).get();
    for (const d of stuck.docs) {
      const at = (d.data().claimedAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      if (Date.now() - at > 5 * 60_000) await d.ref.set({ status: "pending" }, { merge: true });
    }

    const isAuto = (d: FirebaseFirestore.QueryDocumentSnapshot): boolean => String(d.data().authorId ?? "") === "auto";
    const docs = [...snap.docs].sort((a, b) => Number(isAuto(a)) - Number(isAuto(b)));

    const startedAt = Date.now();
    for (const doc of docs) {
      if (Date.now() - startedAt > 85_000) return;

      const it = doc.data() as Record<string, unknown>;
      const chatId = String(it.chatId ?? "");
      const crmMessageId = String(it.crmMessageId ?? doc.id);

      // «Человечная» задержка ещё не истекла — отправим в следующий заход.
      const naa = (it.nextAttemptAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      if (naa > Date.now()) continue;

      // WABA: текст ждёт ответа клиента (для QR-канала не срабатывает).
      if (it.waitWindow === true && !(await windowOpen(chatId))) {
        const created = (it.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? Date.now();
        if (Date.now() - created > 3 * 86400_000) {
          await doc.ref.set({ status: "expired" }, { merge: true });
          await firestore.collection("messages").doc(crmMessageId).set(
            { status: "expired", queued: false, statusError: "Клиент не ответил за 3 дня — сообщение не отправлено" },
            { merge: true },
          );
        }
        continue;
      }

      if (!(await claimOutbox(doc.ref))) continue; // уже забрал триггер
      const slot = await reserveSlot();
      if (!slot.allow) {
        await doc.ref.set({ status: "pending" }, { merge: true });
        return; // лимит исчерпан — продолжим через минуту
      }
      await deliverOutbox(doc.ref, it, outCh.channelId || WAZZUP_CHANNEL_ID.value());
      // Ровный темп нужен автосообщениям (один текст многим). Сообщения
      // менеджеров разным людям — обычная переписка, их не растягиваем.
      if (isAuto(doc)) await sleep(lim.drainGapSec * 1000);
    }
  },
);

/**
 * Быстрые ответы: как только менеджер создал или отредактировал текст,
 * сервер молча готовит рядом 5–6 равнозначных вариантов. В приложении
 * ничего не меняется — менеджер по-прежнему видит и правит один текст.
 */
export const onQuickReplyWritten = onDocumentWritten("quickReplies/{id}", async (event) => {
  const after = event.data?.after;
  if (!after?.exists) return;
  const d = after.data() ?? {};
  const text = String(d.text ?? "").trim();
  if (!text) return;
  // Точный отпечаток: при правке шаблона (сменился дом в адресе, цена) старые
  // варианты обязаны пересобраться. Отпечаток из risk.ts цифры игнорирует и
  // такую правку не замечал — уходил вариант со старым адресом.
  const fp = exactFingerprint(text);
  // Варианты уже готовы для этого текста — выходим (иначе триггер зациклится).
  const have = ((d.variants ?? []) as unknown[]).length;
  if (d.variantsFor === fp && have >= 5) return;
  await after.ref.set(
    { variants: makeVariants(text, 6), variantsFor: fp, variantsAt: ts() },
    { merge: true },
  );
});

/** Проверка «звонящий — админ» для админ-функций канала. */
async function assertAdmin(uid: string | undefined): Promise<void> {
  if (!uid) throw new HttpsError("unauthenticated", "Требуется вход");
  const role = String((await db().collection("users").doc(uid).get()).data()?.role ?? "");
  if (role !== "admin" && role !== "administrator") throw new HttpsError("permission-denied", "Только админ");
}

/**
 * Состояние рабочего канала (callable, любой менеджер): active / qr /
 * disabled и т.п. — чтобы сразу видеть, что номер отвалился.
 */
export const channelStatus = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  try {
    const ch = await currentChannel(WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value());
    return { ok: true, state: ch.state, phone: ch.phone, transport: ch.transport };
  } catch (e) {
    return { ok: false, state: "unknown", error: String(e instanceof Error ? e.message : e) };
  }
});

/** Каналы аккаунта Wazzup (callable, админ): что подключено — QR или WABA. */
export const wazzupChannelList = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (request) => {
  await assertAdmin(request.auth?.uid);
  try {
    const list = await wazzupChannels(WAZZUP_API_KEY.value());
    const active = await currentChannel(WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value());
    return {
      ok: true,
      current: active.channelId,
      channels: list.map((c) => ({
        channelId: c.channelId,
        phone: c.plainId,
        transport: c.transport,
        isWaba: isWaba(c.transport),
        state: c.state,
      })),
    };
  } catch (e) {
    throw new HttpsError("unavailable", String(e instanceof Error ? e.message : e));
  }
});

/** Шаблоны WABA из кабинета Wazzup (callable, админ) + их статус модерации. */
export const wabaTemplates = onCall({ secrets: [WAZZUP_API_KEY] }, async (request) => {
  await assertAdmin(request.auth?.uid);
  try {
    const list = await wazzupTemplates(WAZZUP_API_KEY.value());
    return {
      ok: true,
      templates: list.map((t) => {
        const body = t.components.find((c) => c.type === "BODY");
        const header = t.components.find((c) => c.type === "HEADER");
        // Сколько переменных ждёт шаблон — по числу {{n}} в заголовке и теле.
        const vars = [header?.text ?? "", body?.text ?? ""].join(" ").match(/\{\{\d+\}\}/g)?.length ?? 0;
        return {
          id: t.templateGuid,
          title: t.title || t.name,
          status: t.status,
          category: t.category,
          language: t.language,
          body: (body?.text ?? "").slice(0, 400),
          header: (header?.text ?? "").slice(0, 200),
          vars,
        };
      }),
    };
  } catch (e) {
    throw new HttpsError("unavailable", String(e instanceof Error ? e.message : e));
  }
});

/** Подставить значения в текст шаблона: {{1}}, {{2}} → значения по порядку. */
export function renderTemplate(body: string, values: string[]): string {
  return body.replace(/\{\{(\d+)\}\}/g, (_s, n: string) => values[Number(n) - 1] ?? "");
}

/**
 * Отправка одобренного шаблона WABA списку получателей (callable, админ).
 *
 * Это единственный законный способ написать первым тем, кто не писал вам
 * последние 24 часа. Уходит очередью с паузами: у Meta и Wazzup лимит темпа,
 * а одинаковый текст пачкой — прямой путь к жалобам и падению качества
 * номера. В переписке каждое сообщение видно с пометкой «рассылка».
 */
export const sendWabaTemplate = onCall({ secrets: [WAZZUP_API_KEY, WAZZUP_CHANNEL_ID] }, async (request) => {
  await assertAdmin(request.auth?.uid);
  const uid = request.auth!.uid;
  const d = (request.data ?? {}) as {
    templateId?: string;
    body?: string;
    recipients?: { phone?: string; name?: string; values?: string[] }[];
    gapSec?: number;
  };
  const templateId = String(d.templateId ?? "").trim();
  const body = String(d.body ?? "");
  const list = Array.isArray(d.recipients) ? d.recipients : [];
  if (!templateId) throw new HttpsError("invalid-argument", "Не выбран шаблон");
  if (list.length === 0) throw new HttpsError("invalid-argument", "Нет получателей");
  if (list.length > 200) throw new HttpsError("invalid-argument", "Не больше 200 получателей за раз");

  const ch = await currentChannel(WAZZUP_API_KEY.value(), WAZZUP_CHANNEL_ID.value());
  if (!isWaba(ch.transport)) {
    throw new HttpsError("failed-precondition", "Шаблоны работают только на канале WhatsApp Business API");
  }

  // Пауза между отправками: 20 секунд по умолчанию, меньше 5 не даём.
  const gap = Math.min(Math.max(Math.round(Number(d.gapSec ?? 20) || 20), 5), 300);
  const seen = new Set<string>();
  let index = 0;
  const queued: string[] = [];
  for (const r of list) {
    const phone = String(r.phone ?? "").replace(/\D/g, "");
    if (phone.length < 10 || seen.has(phone)) continue;
    seen.add(phone);
    const values = (r.values ?? []).map((v) => String(v ?? "").trim().slice(0, 300));
    await enqueue({
      kind: "template",
      chatId: phone,
      name: (r.name ?? "").trim() || undefined,
      authorId: uid,
      crmMessageId: randomUUID(),
      templateId,
      templateValues: values,
      text: renderTemplate(body, values),
      broadcast: true,
      reason: "broadcast",
      nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + 5000 + index * gap * 1000),
    });
    queued.push(phone);
    index++;
  }

  await logRisk({
    authorId: uid,
    kinds: ["blast"],
    count: queued.length,
    text: renderTemplate(body, (list[0]?.values ?? []).map(String)),
  });

  return {
    ok: true,
    queued: queued.length,
    skipped: list.length - queued.length,
    gapSec: gap,
    minutes: Math.ceil((queued.length * gap) / 60),
  };
});

/**
 * Переключить рабочий канал и настроить WABA (callable, админ).
 * Пишет config/channel и config/waba, сбрасывает кэши — передеплой не нужен.
 */
export const setChannelConfig = onCall(async (request) => {
  await assertAdmin(request.auth?.uid);
  const d = (request.data ?? {}) as {
    channelId?: string;
    openerTemplateId?: string;
    openerVars?: string[];
    openerCooldownHours?: number;
  };
  if (d.channelId !== undefined) {
    await db().doc("config/channel").set({ channelId: String(d.channelId).trim(), updatedAt: ts() }, { merge: true });
  }
  const waba: Record<string, unknown> = {};
  if (d.openerTemplateId !== undefined) waba.openerTemplateId = String(d.openerTemplateId).trim();
  if (Array.isArray(d.openerVars)) waba.openerVars = d.openerVars.map(String);
  if (typeof d.openerCooldownHours === "number") waba.openerCooldownHours = d.openerCooldownHours;
  if (Object.keys(waba).length) await db().doc("config/waba").set({ ...waba, updatedAt: ts() }, { merge: true });

  resetChannelCache();
  resetWabaCache();
  return { ok: true };
});

/** Редактирование своего сообщения (callable): Wazzup PATCH + Firestore. */
export const editMessage = onCall({ secrets: [WAZZUP_API_KEY] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { messageId?: string; text?: string };
  const messageId = (data.messageId ?? "").trim();
  const text = (data.text ?? "").trim();
  if (!messageId || !text) throw new HttpsError("invalid-argument", "messageId и text обязательны");
  const doc = (await db().collection("messages").doc(messageId).get()).data();
  // Ещё в очереди — правим текст будущей отправки без похода в Wazzup.
  if (doc?.status === "queued") {
    await db().collection("outbox").doc(messageId).set({ text }, { merge: true });
    await db().collection("messages").doc(messageId).set({ text, isEdited: true, updatedAt: ts() }, { merge: true });
    return { ok: true };
  }
  const external = String(doc?.externalMessageId ?? messageId);
  await wazzupEditText(WAZZUP_API_KEY.value(), external, text);
  await db().collection("messages").doc(messageId).set({ text, isEdited: true, updatedAt: ts() }, { merge: true });
  return { ok: true };
});

/** Удаление своего сообщения (callable): DELETE Wazzup + пометка. */
export const deleteMessage = onCall({ secrets: [WAZZUP_API_KEY] }, async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Требуется вход");
  const data = (request.data ?? {}) as { messageId?: string };
  const messageId = (data.messageId ?? "").trim();
  if (!messageId) throw new HttpsError("invalid-argument", "messageId обязателен");
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
 * Входящее медиа Wazzup: contentUri без mediaUrl → скачиваем и кладём в
 * Firebase Storage (durable), пишем публичную ссылку mediaUrl в документ.
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
