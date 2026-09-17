import { onRequest } from "firebase-functions/v2/https";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";
import { randomUUID } from "crypto";
import { TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET } from "./secrets";
import {
  TgApiError,
  tgAnswerCallback,
  tgDownloadFile,
  tgSendTextApi,
  type TgChatMemberUpdated,
  type TgMessage,
  type TgUpdate,
} from "./api";
import {
  TG_REGION,
  countryByPhone,
  extractPhoneFromText,
  tgConvId,
  tgDisplayName,
  tgMsgDocId,
  tgPreview,
  tgTexts,
} from "./common";
import { toWhatsAppAudio } from "../audio";
import { pushToOfflineManagers } from "../push";
import { detectBookingIntent } from "../booking-intent";
import { vacationCfg, vacationText } from "../vacation";
import { ANTHROPIC_API_KEY, maybeAiSuggest } from "../ai-reply";
import { maybeTrainingReply } from "../training-reply";
import { maybePaymentAlert } from "../payment-alert";
import { telegramAutoMessagesOn } from "../auto-messages";
import { detectTopic, isOwnTabTopic } from "../topics";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

/**
 * Приём вебхука Telegram. Делает ровно две вещи: проверяет секрет и пишет
 * сырой апдейт в tgUpdates/{update_id} → сразу 200 (обработка — в триггере
 * tgProcessUpdate). Идемпотентность по update_id бесплатно: повторная доставка
 * перезаписывает СУЩЕСТВУЮЩИЙ документ, а onDocumentCreated срабатывает
 * только на создание — второй обработки не будет.
 */
export const tgWebhook = onRequest({ region: TG_REGION, secrets: [TELEGRAM_WEBHOOK_SECRET] }, async (req, res) => {
  if ((req.get("x-telegram-bot-api-secret-token") ?? "") !== TELEGRAM_WEBHOOK_SECRET.value()) {
    res.status(403).json({ error: "forbidden" });
    return;
  }
  const update = (req.body ?? {}) as TgUpdate;
  if (typeof update.update_id !== "number") {
    res.json({ ok: true, skipped: true });
    return;
  }
  try {
    await db().collection("tgUpdates").doc(String(update.update_id)).set({
      raw: update,
      receivedAt: ts(),
      // TTL-политика Firestore по полю expireAt чистит коллекцию через 7 дней.
      expireAt: admin.firestore.Timestamp.fromMillis(Date.now() + 7 * 86400_000),
    });
    res.json({ ok: true });
  } catch (e) {
    console.error("tgWebhook error", e);
    // 500 → Telegram повторит доставку, апдейт не потеряется.
    res.status(500).json({ error: "internal" });
  }
});

/** Обработка сохранённого апдейта (после мгновенного 200 вебхуку). */
export const tgProcessUpdate = onDocumentCreated(
  { region: TG_REGION, document: "tgUpdates/{id}", secrets: [TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY] },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const u = (snap.data().raw ?? {}) as TgUpdate;
    const token = TELEGRAM_BOT_TOKEN.value();
    try {
      if (u.message) await handleMessage(token, u.message, "bot");
      else if (u.edited_message) await handleEdited(u.edited_message);
      // Telegram Business (личный аккаунт) — приём заложен уже сейчас.
      else if (u.business_message) await handleMessage(token, u.business_message, "personal");
      else if (u.edited_business_message) await handleEdited(u.edited_business_message);
      else if (u.deleted_business_messages) await handleDeletedBusiness(u.deleted_business_messages);
      else if (u.callback_query) await handleCallback(token, u.callback_query.id);
      else if (u.my_chat_member) await handleMyChatMember(u.my_chat_member);
      await snap.ref.set({ status: "done", doneAt: ts() }, { merge: true });
    } catch (e) {
      console.error("tgProcessUpdate error", event.params.id, e);
      await snap.ref.set(
        { status: "error", error: String(e instanceof Error ? e.message : e).slice(0, 500) },
        { merge: true },
      );
    }
  },
);

/** Медиа сообщения → наш тип + file_id для скачивания. */
function pickMedia(
  m: TgMessage,
): { kind: string; fileId: string; fileName: string; contentType?: string } | null {
  const largestPhoto = m.photo && m.photo.length > 0 ? m.photo[m.photo.length - 1] : undefined;
  if (largestPhoto) {
    return { kind: "image", fileId: largestPhoto.file_id, fileName: "photo.jpg", contentType: "image/jpeg" };
  }
  if (m.voice) {
    return { kind: "audio", fileId: m.voice.file_id, fileName: "voice.ogg", contentType: m.voice.mime_type ?? "audio/ogg" };
  }
  if (m.audio) {
    return { kind: "audio", fileId: m.audio.file_id, fileName: m.audio.file_name ?? "audio", contentType: m.audio.mime_type };
  }
  if (m.video) {
    return { kind: "video", fileId: m.video.file_id, fileName: m.video.file_name ?? "video.mp4", contentType: m.video.mime_type ?? "video/mp4" };
  }
  if (m.video_note) {
    return { kind: "video", fileId: m.video_note.file_id, fileName: "video_note.mp4", contentType: "video/mp4" };
  }
  if (m.document) {
    return { kind: "document", fileId: m.document.file_id, fileName: m.document.file_name ?? "file", contentType: m.document.mime_type };
  }
  // Статичные стикеры показываем картинкой; анимированные боту не пригодятся.
  if (m.sticker && !m.sticker.is_animated && !m.sticker.is_video) {
    return { kind: "image", fileId: m.sticker.file_id, fileName: "sticker.webp", contentType: "image/webp" };
  }
  return null;
}

/**
 * Входящее (или исходящее с личного аккаунта) сообщение → Firestore.
 * Модель та же, что у WhatsApp: contacts + conversations + messages, ключи
 * с префиксом tg_. Имя/username обновляются на каждом сообщении.
 */
async function handleMessage(token: string, m: TgMessage, transport: "bot" | "personal"): Promise<void> {
  const chat = m.chat;
  if (!chat || chat.type !== "private" || !m.message_id) return; // группы/каналы вне scope

  const firestore = db();
  const convId = tgConvId(chat.id);
  // Через бота клиент может только писать нам; в business-канале from —
  // владелец аккаунта, когда он ответил сам с телефона.
  const inbound = transport === "bot" ? true : m.from?.id === chat.id;
  const createdAt = m.date ? admin.firestore.Timestamp.fromMillis(m.date * 1000) : admin.firestore.Timestamp.now();

  // /start [метка] — источник из ссылки t.me/<бот>?start=<метка>.
  const rawText = (m.text ?? m.caption ?? "").trim();
  const isStart = transport === "bot" && rawText.startsWith("/start");
  const source = isStart ? (rawText.split(/\s+/)[1] ?? "direct") : null;

  // /promo — служебная команда: бот отвечает готовым постом с inline-кнопкой.
  // Его можно переслать в любой чат/группу — кнопка при пересылке сохраняется.
  // В переписку и карточки ничего не пишем.
  if (transport === "bot" && rawText.startsWith("/promo")) {
    try {
      const t = await tgTexts();
      await tgSendTextApi(token, {
        chatId: chat.id,
        text: t.promoText,
        replyMarkup: { inline_keyboard: [[{ text: t.promoButton, url: t.promoUrl }]] },
      });
    } catch (e) {
      console.error("tg promo error", e);
    }
    return;
  }

  // Собственный номер клиента (кнопка «Поделиться номером»). Пересланный
  // чужой контакт телефоном клиента не считаем.
  const ownContact = m.contact && (m.contact.user_id === undefined || m.contact.user_id === chat.id) ? m.contact : null;
  const phone = ownContact?.phone_number ? ownContact.phone_number.replace(/\D/g, "") : null;

  // Карточку читаем ДО вычисления имени: как только номер известен (пришёл
  // сейчас или сохранён раньше), клиент в списке и шапке отображается
  // НОМЕРОМ, а не именем/username из Telegram (политика CRM — контакты по
  // номеру). До номера — имя из Telegram.
  const contactRef = firestore.collection("contacts").doc(convId);
  const contactSnap = await contactRef.get();
  const rawStored = contactSnap.data()?.phone;
  const storedPhone = typeof rawStored === "string" && rawStored.length > 0 ? rawStored : null;

  // Клиент написал номер ТЕКСТОМ: фиксируем первый увиденный и дальше не
  // переписываем. Перебить его может только кнопка «Поделиться номером»
  // (подтверждённый номер аккаунта).
  const typedPhone =
    inbound && !phone && !storedPhone && !isStart && rawText ? extractPhoneFromText(rawText) : null;

  const newPhone = phone ?? typedPhone; // что записываем в карточку сейчас
  const knownPhone = phone ?? storedPhone ?? typedPhone;
  const name = knownPhone
    ? `+${knownPhone}`
    : tgDisplayName({
        firstName: chat.first_name,
        lastName: chat.last_name,
        username: chat.username,
        chatId: chat.id,
      });

  const media = pickMedia(m);
  const type = media?.kind ?? "text";
  let text: string | null = rawText || null;
  if (!text && ownContact) text = null; // телефон уйдёт в карточку, не в текст
  else if (!text && m.contact && !ownContact) text = `[контакт ${m.contact.phone_number ?? ""}]`.trim();
  else if (!text && !media && m.sticker) text = m.sticker.emoji ?? "[стикер]";
  else if (!text && !media && m.location) text = "[геолокация]";

  const preview = ownContact ? `📱 +${phone}` : tgPreview(type, text);

  // ── Карточка клиента (contacts; contactRef/contactSnap прочитаны выше) ──
  const identity: Record<string, unknown> = {
    tgId: String(chat.id),
    username: chat.username ?? null,
    firstName: chat.first_name ?? null,
    lastName: chat.last_name ?? null,
    name,
    chatType: "telegram",
    transport,
    lastMessageAt: createdAt,
    updatedAt: ts(),
  };
  if (m.business_connection_id) identity.businessConnectionId = m.business_connection_id;
  if (!contactSnap.exists) {
    await contactRef.set({
      ...identity,
      phone: newPhone,
      country: newPhone ? countryByPhone(newPhone) : null,
      phoneSource: phone ? "shared" : typedPhone ? "typed" : null,
      source,
      status: "new",
      optIn: true,
      responsibleId: null,
      responsibleName: null,
      createdAt: ts(),
    });
  } else {
    const patch = { ...identity };
    if (phone) {
      // Кнопка «Поделиться номером» — подтверждённый номер, может уточнить
      // набранный вручную.
      patch.phone = phone;
      patch.country = countryByPhone(phone);
      patch.phoneSource = "shared";
    } else if (typedPhone) {
      // typedPhone вычисляется только когда номера ещё нет — первый
      // написанный текстом номер фиксируется и больше не меняется.
      patch.phone = typedPhone;
      patch.country = countryByPhone(typedPhone);
      patch.phoneSource = "typed";
    }
    // Источник — first-touch: не перетираем, если уже известен.
    if (source && !contactSnap.data()?.source) patch.source = source;
    if (inbound) patch.optIn = true; // клиент пишет — значит бот не заблокирован
    await contactRef.set(patch, { merge: true });
  }

  // ── Диалог (conversations) ──────────────────────────────────────────────
  const conv: Record<string, unknown> = {
    contactId: convId,
    tgId: String(chat.id),
    name,
    chatType: "telegram",
    status: "open",
    lastMessageAt: createdAt,
    lastMessagePreview: preview,
    lastOutbound: !inbound,
    lastAuthorId: null,
    lastAuthorName: inbound ? null : (m.from?.first_name ?? "Телефон"),
    updatedAt: ts(),
  };
  if (newPhone) conv.phone = newPhone;
  if (inbound) {
    conv.unreadCount = admin.firestore.FieldValue.increment(1);
    conv.hasInbound = true;
    conv.lastInboundAt = createdAt;
    // Тема обращения — по ключевым словам, только по входящим и только
    // вперёд: старую переписку не переразмечаем. Раздел, выбранный менеджером
    // руками (topicLocked), словами не перетирается.
    const topic = await detectTopic(text ?? "");
    const cur = (await firestore.doc(`conversations/${convId}`).get()).data();
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
  }
  await firestore.collection("conversations").doc(convId).set(conv, { merge: true });

  // ── Сообщение (messages, ключ tg_<chat>_<mid> → идемпотентно) ───────────
  const msgRef = firestore.collection("messages").doc(tgMsgDocId(chat.id, m.message_id));
  const msgDoc: Record<string, unknown> = {
    conversationId: convId,
    chatId: convId,
    tgMessageId: m.message_id,
    direction: inbound ? "inbound" : "outbound",
    type,
    text: ownContact ? `📱 Поделился номером: +${phone}` : text,
    status: inbound ? "received" : "sent",
    authorName: inbound ? null : (m.from?.first_name ?? null),
    createdAt,
  };
  if (transport === "personal") msgDoc.viaBusiness = true;
  await msgRef.set(msgDoc, { merge: true });

  // ── Медиа: скачиваем через getFile → Storage (ссылки Telegram временные) ─
  if (media) {
    try {
      const file = await tgDownloadFile(token, media.fileId);
      const bucket = admin.storage().bucket();
      const dlToken = randomUUID();
      let path = `media/tg/in/${tgMsgDocId(chat.id, m.message_id)}`;
      let outType = file.contentType ?? media.contentType ?? "application/octet-stream";
      await bucket.file(path).save(file.bytes, {
        metadata: { contentType: outType, metadata: { firebaseStorageDownloadTokens: dlToken } },
      });
      // Голосовые Telegram приходят в OGG/Opus — iPhone этот формат не
      // проигрывает вовсе. Перекодируем в MP3 (тот же ffmpeg, что и для
      // WhatsApp): играет везде. Не вышло — остаётся исходный OGG.
      if (media.kind === "audio" && /ogg|opus/i.test(outType)) {
        const mp3 = await toWhatsAppAudio(path);
        if (mp3) {
          await bucket.file(mp3).setMetadata({ metadata: { firebaseStorageDownloadTokens: dlToken } });
          path = mp3;
          outType = "audio/mpeg";
        }
      }
      const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(path)}?alt=media&token=${dlToken}`;
      await msgRef.set(
        { mediaUrl: url, mediaContentType: outType, fileName: media.fileName },
        { merge: true },
      );
    } catch (e) {
      const big = e instanceof TgApiError && /too big/i.test(e.description);
      console.error("tg media download error", e);
      await msgRef.set(
        { statusError: big ? "Файл больше 20 МБ — Telegram не отдаёт его ботам" : "Файл не скачался из Telegram" },
        { merge: true },
      );
    }
  }

  // ── Сценарий первого контакта (только бот-транспорт) ────────────────────
  // Автоответы разделены по темам: приём / обучение / БАДы. Тема — по метке
  // ссылки, по тексту или по уже поставленной метке чата. Пациентское
  // приветствие («гражданство пациента, город, что беспокоит») ученикам и
  // покупателям БАДов не уходит — у них свои тексты.
  const knownConv = (await firestore.doc(`conversations/${convId}`).get()).data() ?? {};
  const known = knownConv.topic;
  const topicLocked = knownConv.topicLocked === true;
  const linkTopic =
    source == null ? null
      : /obuch|обуч|training|edu/i.test(source) ? "training"
        : /bad|бад|supp|vitamin/i.test(source) ? "supplements"
          : null;
  // Раздел, закреплённый менеджером руками, метки ссылок не перебивают.
  const ownTabTopic = topicLocked
    ? (isOwnTabTopic(known) ? known : null)
    : linkTopic ?? (await detectTopic(rawText)) ?? (isOwnTabTopic(known) ? known : null);
  if (ownTabTopic && isStart && !topicLocked) {
    await firestore.collection("conversations").doc(convId).set({ topic: ownTabTopic }, { merge: true });
  }
  // Общий рубильник: когда автосообщения выключены, менеджеры здороваются
  // сами — бот не пишет клиенту ни приветствия, ни «Информации о приёме».
  const autoMsgOn = await telegramAutoMessagesOn();
  if (isStart && autoMsgOn) {
    // Отпуск/недоступны: если включено в настройках, первому обращению
    // уходит это вместо обычного приветствия — независимо от темы, отвечать
    // всё равно некому. Существующим чатам (не /start) ничего не шлём.
    const vac = await vacationCfg();
    await botReply(token, chat.id, async (t) => ({
      text: vac.enabled
        ? vacationText(vac, convId)
        : ownTabTopic === "training"
          ? t.greetingTraining
          : ownTabTopic === "supplements"
              ? t.greetingSupplements
              : t.greeting,
      replyMarkup: {
        keyboard: [[{ text: t.shareButton, request_contact: true }]],
        resize_keyboard: true,
        one_time_keyboard: true,
      },
    }));
  }
  // Ответ «номер получен» после кнопки «Поделиться номером» убран (решение
  // владельца 2026-09-06): дальше с клиентом здоровается менеджер, а не бот.
  // Клавиатура с кнопкой одноразовая (one_time_keyboard) и прячется сама.

  // Автоматическая «Информация о приёме» иногородним сразу после номера
  // убрана вместе с ответом «номер получен» (владелец, 2026-09-07): после
  // кнопки «Поделиться номером» бот молчит, условия для приезжающих менеджер
  // отправляет сам быстрым ответом.

  // ── Пуш менеджерам о входящем (тот же механизм, что у WhatsApp) ─────────
  if (inbound && !isStart) {
    try {
      await pushToOfflineManagers([{ chatId: convId, title: `CRM · ${name}`, body: preview.slice(0, 140) }]);
    } catch (e) {
      console.error("tg push error", e);
    }
    // Черновик ответа для менеджера (если включён в настройках) — реальный
    // первый вопрос клиента, а не сам /start. Ждём, а не «бросаем и забыли»:
    // Cloud Functions может остановить инстанс сразу после ответа обработчика,
    // недожатый запрос к API просто не долетел бы.
    try {
      await maybeAiSuggest(convId, token);
    } catch (e) {
      console.error("aiReply tg error", e);
    }
    // Ученики — свой сценарий на текстах раздела «Обучение». Внутри стоит
    // проверка темы, поэтому пациентов и учеников эти два вызова не путают.
    try {
      await maybeTrainingReply(convId, token);
    } catch (e) {
      console.error("trainingReply tg error", e);
    }
    // Клиент готов платить — отдельный сигнал руководителю, чтобы выставить
    // счёт (обычный пуш о входящем теряется в общем потоке).
    try {
      await maybePaymentAlert(convId, rawText, token);
    } catch (e) {
      console.error("paymentAlert tg error", e);
    }
  } else if (isStart) {
    try {
      await pushToOfflineManagers([
        { chatId: convId, title: "CRM · Новый клиент в Telegram", body: `${name}${source && source !== "direct" ? ` · ${source}` : ""}` },
      ]);
    } catch (e) {
      console.error("tg push error", e);
    }
  }
}

/**
 * Автоответ бота (приветствие / «номер получен»): отправить и сохранить в
 * переписку, чтобы менеджеры видели, что бот уже ответил. Ошибка отправки не
 * ломает приём сообщения.
 */
async function botReply(
  token: string,
  chatId: number,
  build: (t: Awaited<ReturnType<typeof tgTexts>>) => Promise<{ text: string; replyMarkup?: unknown }>,
): Promise<boolean> {
  try {
    const texts = await tgTexts();
    const p = await build(texts);
    const sent = await tgSendTextApi(token, { chatId, text: p.text, replyMarkup: p.replyMarkup });
    const firestore = db();
    const convId = tgConvId(chatId);
    await firestore.collection("messages").doc(tgMsgDocId(chatId, sent.message_id)).set({
      conversationId: convId,
      chatId: convId,
      tgMessageId: sent.message_id,
      direction: "outbound",
      type: "text",
      text: p.text,
      status: "sent",
      authorId: "auto",
      isAuto: true,
      createdAt: ts(),
    });
    await firestore.collection("conversations").doc(convId).set(
      {
        lastMessageAt: ts(),
        lastMessagePreview: p.text.slice(0, 120),
        lastOutbound: true,
        lastAuthorId: "auto",
        lastAuthorName: null,
        updatedAt: ts(),
      },
      { merge: true },
    );
    return true;
  } catch (e) {
    console.error("tg botReply error", e);
    return false;
  }
}

/** Клиент отредактировал сообщение — обновляем текст + пометка «изм.». */
async function handleEdited(m: TgMessage): Promise<void> {
  const chat = m.chat;
  if (!chat || chat.type !== "private" || !m.message_id) return;
  const ref = db().collection("messages").doc(tgMsgDocId(chat.id, m.message_id));
  const snap = await ref.get();
  if (!snap.exists) return; // правка неизвестного сообщения — игнор
  const text = (m.text ?? m.caption ?? "").trim();
  if (!text) return;
  await ref.set({ text, isEdited: true, updatedAt: ts() }, { merge: true });
}

/** Telegram Business: клиент/владелец удалил сообщения — мягкая пометка. */
async function handleDeletedBusiness(d: {
  chat?: { id?: number; type?: string };
  message_ids?: number[];
}): Promise<void> {
  const chatId = d.chat?.id;
  if (!chatId || !Array.isArray(d.message_ids)) return;
  const firestore = db();
  for (const mid of d.message_ids.slice(0, 100)) {
    const ref = firestore.collection("messages").doc(tgMsgDocId(chatId, mid));
    const snap = await ref.get();
    if (snap.exists) await ref.set({ isDeleted: true, updatedAt: ts() }, { merge: true });
  }
}

/** Инлайн-кнопок пока нет — просто снимаем «часики» с кнопки. */
async function handleCallback(token: string, callbackQueryId: string | undefined): Promise<void> {
  if (!callbackQueryId) return;
  await tgAnswerCallback(token, callbackQueryId).catch(() => {});
}

/**
 * my_chat_member: клиент заблокировал бота (kicked) → optIn=false, карточка
 * помечена; разблокировал (member) → optIn=true.
 */
async function handleMyChatMember(u: TgChatMemberUpdated): Promise<void> {
  const chat = u.chat;
  if (!chat || chat.type !== "private") return;
  const status = u.new_chat_member?.status ?? "";
  const convId = tgConvId(chat.id);
  if (status === "kicked" || status === "left") {
    await db().collection("contacts").doc(convId).set(
      { optIn: false, optOutAt: ts(), optOutReason: "blocked", updatedAt: ts() },
      { merge: true },
    );
  } else if (status === "member") {
    await db().collection("contacts").doc(convId).set({ optIn: true, updatedAt: ts() }, { merge: true });
  }
}
