/**
 * Ответ пациенту от ИИ. По умолчанию — черновик-подсказка менеджеру (он
 * решает, отправлять ли); на обкаточном номере может отвечать сам, см.
 * config/aiReply ниже.
 *
 * База знаний — реальные тексты быстрых ответов (quickReplies), а не
 * отдельно придуманный текст: тема «Обучение» из базы исключена — там свой
 * сценарий и свои тексты. Модель не сочиняет ответ, а ВЫБИРАЕТ подходящий
 * готовый текст, и уходит он дословно из базы.
 *
 * Цена зависит от страны пациента: Казахстан — раздел «Прайс» (дешевле),
 * остальные — «Для пациентов из других стран» (дороже, плюс реквизиты
 * предоплаты в рублях). Страна определяется не только по коду номера — что
 * пациент сказал про себя в переписке, важнее (симка бывает чужой страны).
 *
 * Включается переключателем в настройках приложения (config/aiReply.enabled,
 * по умолчанию выключено). Любая ошибка (нет ключа, сеть, лимит) молча
 * проглатывается — это необязательная подсказка, а не критичный путь.
 */
import * as admin from "firebase-admin";
import { randomUUID } from "crypto";
import Anthropic from "@anthropic-ai/sdk";
import { defineSecret } from "firebase-functions/params";
import { enqueue } from "./limits";
import { QuickReply, patientKnowledge } from "./quick-replies";
import { normalizePhone, toAlternating } from "./chat-context";
import { tgSendTextApi } from "./telegram/api";
import { countryByPhone } from "./telegram/common";
import { isOwnTabTopic } from "./topics";

export const ANTHROPIC_API_KEY = defineSecret("ANTHROPIC_API_KEY");

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

/**
 * Модель можно сменить без деплоя — config/aiReply.model. Haiku слишком
 * часто выбирал «близкий по смыслу» готовый ответ вместо точного (например
 * общий блок «Для России информация» вместо блока с ценой), поэтому по
 * умолчанию Sonnet: разница в цене за сообщение — доли тенге, а ошибка в
 * ответе про цену стоит клиента.
 */
const DEFAULT_MODEL = "claude-sonnet-5";
const ALLOWED_MODELS = ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5"];

function pickModel(v: unknown): string {
  const m = String(v ?? "").trim();
  return ALLOWED_MODELS.includes(m) ? m : DEFAULT_MODEL;
}

/**
 * Скачивает вложение (фото или PDF заключения МРТ) и отдаёт в base64 —
 * Claude принимает изображения/документы только так, ссылкой их не
 * скормить. Файлы небольшие (пара МБ), поэтому целиком в память — ок.
 */
async function fetchMediaBase64(url: string, fallbackMime: string): Promise<{ data: string; mediaType: string } | null> {
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    const buf = Buffer.from(await res.arrayBuffer());
    const mediaType = res.headers.get("content-type")?.split(";")[0]?.trim() || fallbackMime;
    return { data: buf.toString("base64"), mediaType };
  } catch (e) {
    console.error("aiReply fetchMediaBase64 fail", url, String(e instanceof Error ? e.message : e));
    return null;
  }
}

const quickReplyKnowledge = patientKnowledge;

/**
 * Разделы про цену/оплату — гражданам Казахстана и «остальным» отвечает
 * РАЗНАЯ информация (не только сумма, но и способ оплаты: Kaspi для КЗ,
 * банковский перевод в рублях для остальных). Модель однажды перепутала их,
 * хотя инструкция прямо запрещала брать чужой раздел, — значит инструкции
 * недостаточно, если оба раздела лежат перед ней одновременно. Поэтому
 * чужой раздел цены просто не попадает в материалы: выбирать не из чего.
 */
const KZ_ONLY_TITLE = "прайс";
// «ПРЕДОПЛАТА РОССИЯ» сюда НЕ входит намеренно: это реквизиты для оплаты
// российской картой, то есть способ оплаты, а не гражданство. Казахстанец
// вполне может платить российской картой — и когда этот раздел был привязан
// к стране, бот вместо готовых реквизитов отвечал «пришлём отдельно, дайте
// немного времени», хотя карта лежала в быстрых ответах.
const OTHER_ONLY_TITLES = ["для пациентов из других стран", "для россии информация"];

function filterByCitizen(qr: QuickReply[], citizen: "kz" | "other"): QuickReply[] {
  return qr.filter((q) => {
    const t = q.title.toLowerCase();
    if (t === KZ_ONLY_TITLE) return citizen === "kz";
    if (OTHER_ONLY_TITLES.includes(t)) return citizen === "other";
    return true;
  });
}

/**
 * Гражданство по коду номера — только ПРЕДПОЛОЖЕНИЕ. Пациент с казахстанской
 * симкой вполне может быть россиянином (и наоборот): в реальном чате человек
 * писал «нет я гражданин России», а бот всё равно слал казахстанский раздел,
 * потому что смотрел исключительно на +7 747. Поэтому сказанное пациентом
 * прямым текстом важнее номера: сначала ищем явное упоминание страны/города
 * в ЕГО сообщениях (наши тексты не смотрим — там «приезжают из других стран»
 * встречается в самом шаблоне), начиная с самых свежих.
 */
const KZ_PLACES = [
  "казахстан", "қазақстан", "казахстанец", "казахстанка", "астана", "астане", "астаны", "алматы",
  "шымкент", "караганда", "қарағанды", "актобе", "ақтөбе", "тараз", "павлодар", "семей", "атырау",
  "костанай", "қостанай", "кызылорда", "қызылорда", "уральск", "петропавловск", "талдыкорган",
  "туркестан", "түркістан", "экибастуз", "темиртау", "кокшетау", "көкшетау", "усть-каменогорск",
];
const OTHER_PLACES = [
  "россия", "россии", "россию", "россиянин", "россиянка", "российск", "москва", "москве", "москвы",
  "питер", "санкт-петербург", "екатеринбург", "новосибирск", "казань", "самара", "краснодар",
  "ростов", "воронеж", "челябинск", "красноярск", "пермь", "волгоград", "саратов", "тюмень",
  "тольятти", "ижевск", "барнаул", "ульяновск", "иркутск", "хабаровск", "владивосток", "махачкала",
  "оренбург", "кемерово", "новокузнецк", "рязань", "астрахань", "сургут", "нижневартовск", "якутск",
  "грозный", "белгород", "ставрополь", "калининград", "кыргызстан", "бишкек", "узбекистан",
  "ташкент", "самарканд", "таджикистан", "душанбе", "туркменистан", "азербайджан", "армения",
  "ереван", "тбилиси", "украина", "беларусь", "минск", "монголия", "турция", "стамбул", "германия",
  "израиль", "дубай", "оаэ", "америк", "канада", "лондон", "париж",
];

function citizenFromChat(inboundTexts: string[]): "kz" | "other" | null {
  for (const raw of inboundTexts) {
    const t = raw.toLowerCase();
    const kz = KZ_PLACES.some((w) => t.includes(w));
    const other = OTHER_PLACES.some((w) => t.includes(w));
    if (kz !== other) return kz ? "kz" : "other"; // упомянуты обе страны сразу — неоднозначно, смотрим дальше
  }
  return null;
}

/** Заголовок «нет подходящего готового ответа» — зарезервированное значение. */
const NO_MATCH = "__none__";

/**
 * Инструмент вместо свободного текста: модель ВЫБИРАЕТ готовый быстрый
 * ответ по заголовку (из enum — физически не может назвать чужой/несущест-
 * вующий), а не пересказывает его своими словами. Мы потом берём текст сами
 * из базы — дословно, без риска, что модель что-то переформулирует или
 * упустит цифру. custom_text — только запасной путь, если ни один готовый
 * ответ вопрос не закрывает.
 */
function buildReplyTool(qr: QuickReply[], citizen: "kz" | "other"): Anthropic.Tool {
  const titles = filterByCitizen(qr, citizen).map((q) => q.title);
  return {
    name: "reply",
    description: "Ответить пациенту: либо готовым текстом клиники (по заголовку), либо, если ни один не подходит, коротким своим текстом.",
    input_schema: {
      type: "object",
      properties: {
        patient_country: {
          type: "string",
          enum: ["kz", "other"],
          description:
            "Откуда пациент: \"kz\" — гражданин Казахстана / живёт в Казахстане, \"other\" — из любой другой страны. Определи по ПЕРЕПИСКЕ: если пациент сам написал, откуда он или откуда приедет, это важнее подсказки по коду номера (симка может быть чужой страны). Если в переписке об этом ничего нет — оставь как в подсказке.",
        },
        quick_reply_title: {
          type: "string",
          enum: [...titles, NO_MATCH],
          description: `Точный заголовок готового ответа из списка, который ПОЛНОСТЬЮ закрывает вопрос пациента. "${NO_MATCH}", если ни один не подходит. Если patient_country НЕ совпадает с подсказкой, список ниже собран не под ту страну — всё равно честно укажи страну, правильный текст подставим мы.`,
        },
        custom_text: {
          type: "string",
          description: `Короткий ответ (1–2 предложения) своими словами по фактам из материалов. Заполняй, только если quick_reply_title = "${NO_MATCH}"; иначе оставь пустой строкой.`,
        },
      },
      required: ["patient_country", "quick_reply_title", "custom_text"],
    },
  };
}

function buildSystemPrompt(qr: QuickReply[], citizen: "kz" | "other", autoSend: boolean): string {
  const material = filterByCitizen(qr, citizen)
    .map((q) => `### ${q.title}\n${q.text}`)
    .join("\n\n");
  const role = autoSend
    ? // Автоотправка (пока — только тестовый номер): текст уходит клиенту
      // БЕЗ проверки менеджером, значит модель обязана писать так, будто
      // сама и есть клиника, а не описывать, что она составляет черновик
      // для кого-то другого — иначе фразы вроде «вот черновик ответа для
      // менеджера» уходят прямо пациенту, что уже случалось.
      "Ты пишешь пациенту в мессенджере ОТ ЛИЦА команды клиники остеопатии Dr. Toitayev (Астана), напрямую — это реальная переписка, не черновик для кого-то ещё."
    : "Ты помогаешь менеджеру клиники остеопатии Dr. Toitayev (Астана) составить черновик ответа пациенту в мессенджере. Твой текст менеджер прочитает и решит, отправлять как есть, поправить или отправить своё — ты НЕ пишешь клиенту напрямую.";
  return [
    role,
    "Отвечаешь ТОЛЬКО через инструмент reply.",
    "",
    `ПОДСКАЗКА ПО ПАЦИЕНТУ: похоже, ${citizen === "kz" ? "гражданин Казахстана" : "из другой страны (не Казахстан)"}. Это предположение по коду номера и переписке — если пациент сам сказал другое, верь ЕМУ и укажи это в patient_country. Материалы ниже собраны под подсказку: раздел про цену/оплату там только для этой страны.`,
    "",
    "ПРАВИЛА:",
    "0. Сначала определи patient_country по переписке, потом выбирай ответ.",
    `1. Если вопрос пациента ПОЛНОСТЬЮ закрывается одним из готовых ответов ниже (в том числе цена, обучение, БАДы, адрес, расписание) — укажи его заголовок в quick_reply_title. Готовые ответы уходят ДОСЛОВНО, как в базе, — не переписывай, не сокращай и не пересказывай их в custom_text.`,
    `2. custom_text заполняй, только если ни один готовый ответ не подходит целиком (quick_reply_title = "${NO_MATCH}") — например, это благодарность, короткая реплика не по теме материалов, или нужно объединить пару фактов. Тогда — максимально коротко, 1–2 предложения, без списков и длинных пояснений, без вступлений вроде «Вот ответ:».`,
    "3. НЕЛЬЗЯ вместо ответа (готового или своего) отправлять пациента звонить, писать отдельно менеджеру, искать телефон/адрес в 2ГИС и т.п., если ответ есть в материалах — это уклонение, а не ответ. Перенаправлять к менеджеру можно ТОЛЬКО когда в материалах правда нет ответа на конкретный вопрос.",
    "4. Пиши (в custom_text) от лица команды клиники: только «мы», «у нас», «свяжемся» — НИКОГДА «я», «мне», «свяжусь».",
    "5. Никогда не ставь диагноз и не обещай результат лечения.",
    "6. Отвечай на языке пациента — русском, казахском, английском, любом. Ты свободно понимаешь и пишешь по-казахски НЕ ХУЖЕ, чем по-русски. Никогда не говори, что не понимаешь язык, и не проси писать на другом.",
    "7. Если пациент спрашивает про запись на приём или прямо хочет записаться, а готового ответа под это нет — в custom_text ПЕРЕД тем как называть дату или подтверждать запись, попроси прислать заключение МРТ (если снимков нет — коротко описать жалобы); скажи, что доктор посмотрит и решит, можно ли записать. Дату/время не называй, пока этого не попросил.",
    "8. Спрашивают ЦЕНУ/стоимость/сколько стоит — выбирай раздел, где реально есть сумма, а не общий блок про приём, показания и противопоказания. Спрашивают реквизиты/куда платить — раздел с реквизитами.",
    "9. Просят РЕКВИЗИТЫ на оплату/предоплату — не обещай «пришлём отдельно» и не тяни время, реквизиты есть в материалах: при оплате российской картой или в рублях отправляй раздел с картой (он подходит пациенту любого гражданства, это способ оплаты, а не страна). Если платят через Kaspi — реквизитов Kaspi в материалах нет, попроси номер телефона, к которому привязан Kaspi.",
    "10. Если пациент прислал фото или PDF — вероятно, заключение МРТ; готового ответа под это нет, пиши custom_text. Поблагодари и скажи, что доктор посмотрит и решит, можно ли записать (если это явно не медицинский документ — вежливо уточни, что прислали). НЕ описывай содержимое снимка/заключения, не комментируй диагноз или находки, не говори «всё в порядке» или «есть проблема» — это решает только врач.",
    "",
    "МАТЕРИАЛЫ (быстрые ответы клиники — заголовок и текст ДОСЛОВНО):",
    material,
  ].join("\n");
}

/**
 * Один запрос к Claude через инструмент reply. Возвращает готовый текст —
 * либо ДОСЛОВНО из базы (если модель выбрала заголовок), либо custom_text.
 * Заголовок сверяется с тем же отфильтрованным по гражданству списком, что
 * дан модели, — даже если что-то пошло не так, чужую цену не подставить.
 */
type ReplyOut = { country: "kz" | "other"; text: string | null };

async function runReply(
  qr: QuickReply[],
  citizen: "kz" | "other",
  autoSend: boolean,
  model: string,
  messages: Anthropic.MessageParam[],
): Promise<ReplyOut | null> {
  const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY.value() });
  const tool = buildReplyTool(qr, citizen);
  const res = await client.messages.create({
    model,
    max_tokens: 400,
    system: buildSystemPrompt(qr, citizen, autoSend),
    tools: [tool],
    tool_choice: { type: "tool", name: "reply" },
    messages,
  });
  const use = res.content.find((b): b is Anthropic.ToolUseBlock => b.type === "tool_use");
  const input = use?.input as { patient_country?: string; quick_reply_title?: string; custom_text?: string } | undefined;
  if (!input) return null;
  const country: "kz" | "other" = input.patient_country === "other" ? "other" : input.patient_country === "kz" ? "kz" : citizen;
  const title = (input.quick_reply_title ?? "").trim();
  if (title && title !== NO_MATCH) {
    const match = filterByCitizen(qr, citizen).find((q) => q.title === title);
    if (match) return { country, text: match.text }; // дословно из базы — не то, что напечатала модель
  }
  return { country, text: input.custom_text?.trim() || null };
}

/**
 * Ответ с проверкой страны: материалы фильтруются по нашему предположению, но
 * модель заодно говорит, откуда пациент НА САМОМ ДЕЛЕ. Если она не согласна —
 * пересобираем материалы под верную страну и спрашиваем заново. Второй запрос
 * случается редко (только при расхождении), зато перед моделью всегда лежит
 * ровно один раздел с ценой и перепутать их физически нечем.
 */
async function replyWithCountryCheck(
  qr: QuickReply[],
  guess: "kz" | "other",
  autoSend: boolean,
  model: string,
  messages: Anthropic.MessageParam[],
): Promise<ReplyOut | null> {
  const first = await runReply(qr, guess, autoSend, model, messages);
  if (!first || first.country === guess) return first;
  return runReply(qr, first.country, autoSend, model, messages);
}

/**
 * Черновик для чата chatId — если включено, чат новый (не старше 10 минут
 * с первого сообщения) и тема не «своя» (не обучение/БАДы).
 *
 * config/aiReply.testPhone — обкатка на одном живом номере: если задан,
 * работает ТОЛЬКО с чатом этого номера (WhatsApp и Telegram — по полю
 * phone, оно общее для обоих), остальные чаты пропускаются целиком, даже
 * если enabled=true. Для тестового номера сняты «только новый чат» и
 * «один раз навсегда» — иначе не на чем было бы проверять: тестовый чат
 * почти наверняка старый, а хочется слать вопросы один за другим.
 *
 * config/aiReply.autoSend — ИИ отвечает клиенту САМ, без подтверждения
 * менеджера. Работает ТОЛЬКО вместе с testPhone и ТОЛЬКО внутри чата этого
 * номера (`autoSend && isTestChat` — не развязаны специально): включить
 * автоотправку на реальных чатах одним флагом нельзя, для этого пришлось
 * бы сначала расширить testPhone на всех клиентов, а это уже отдельное,
 * осознанное решение, не побочный эффект.
 *
 * tgToken нужен только для автоотправки в Telegram (у WhatsApp своя очередь
 * enqueue, токен бота ей не нужен) — передаётся вызывающим кодом, у
 * которого он уже есть под рукой.
 */
export async function maybeAiSuggest(chatId: string, tgToken?: string): Promise<void> {
  const cfg = (await db().doc("config/aiReply").get()).data() ?? {};
  if (cfg.enabled !== true) return;

  const convRef = db().doc(`conversations/${chatId}`);
  const conv = (await convRef.get()).data() ?? {};
  if (conv.blocked === true) return;
  if (isOwnTabTopic(conv.topic)) return;

  const testPhone = normalizePhone(cfg.testPhone);
  const isTestChat = testPhone.length > 0 && normalizePhone(conv.phone) === testPhone;
  if (testPhone.length > 0 && !isTestChat) return; // обкатка только на одном номере — остальные не трогаем
  const autoSend = cfg.autoSend === true && isTestChat;

  // Вся недавняя переписка, не только последнее сообщение — «полноценный
  // менеджер» должен помнить, что клиент уже написал раньше, а не отвечать
  // так, будто чат начался с нуля (было именно так и путало клиентов).
  const histSnap = await db()
    .collection("messages")
    .where("conversationId", "==", chatId)
    .orderBy("createdAt", "desc")
    .limit(16)
    .get();
  const histDesc = histSnap.docs.map((d) => d.data());
  const lastInboundDoc = histSnap.docs.find((d) => d.data().direction === "inbound");
  const lastInbound = lastInboundDoc?.data();
  if (!lastInbound || !lastInboundDoc) return;

  // Wazzup/Telegram доставляют один и тот же апдейт по нескольку раз, и чем
  // дольше отвечает наш обработчик (а запрос к модели — это секунды), тем
  // охотнее они шлют повтор. Проверка «когда отвечали в прошлый раз» обычным
  // чтением тут не спасает: все дубли успевают прочитать старое значение,
  // пока первый ещё ждёт модель, — и клиент получает один и тот же текст
  // четыре раза подряд (так и случилось в тестовом чате 20.08). Поэтому право
  // ответить занимается ОДНОЙ транзакцией и до обращения к модели: выигрывает
  // ровно один вызов, остальные выходят молча, не потратив ни токена.
  const claimed = await db().runTransaction(async (tx) => {
    const fresh = (await tx.get(convRef)).data() ?? {};
    if (!isTestChat && fresh.aiSuggestionAt) return false; // уже предлагали в этом чате — не спамим менеджера
    if (isTestChat && !autoSend && fresh.aiSuggestion) return false; // прошлую подсказку ещё не разобрали
    if (fresh.aiClaimMsgId === lastInboundDoc.id) return false; // на это сообщение уже отвечали
    const claimAt = (fresh.aiClaimAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    if (Date.now() - claimAt < 8000) return false;
    tx.set(convRef, { aiClaimAt: ts(), aiClaimMsgId: lastInboundDoc.id }, { merge: true });
    return true;
  });
  if (!claimed) return;

  const msgType = String(lastInbound.type ?? "text");
  const mime = String(lastInbound.mediaContentType ?? "").toLowerCase();
  const isImage = msgType === "image" || mime.startsWith("image/");
  const isPdf = msgType === "document" && (mime.includes("pdf") || String(lastInbound.fileName ?? "").toLowerCase().endsWith(".pdf"));

  let lastContent: Anthropic.MessageParam["content"] | null = null;
  if (isImage || isPdf) {
    // Фото/PDF — предположительно заключение МРТ (см. правило 8 в промпте).
    const mediaUrl = String(lastInbound.mediaUrl ?? "");
    if (!mediaUrl) return;
    const media = await fetchMediaBase64(mediaUrl, isPdf ? "application/pdf" : "image/jpeg");
    if (!media) return;
    const IMAGE_TYPES = ["image/jpeg", "image/png", "image/gif", "image/webp"] as const;
    const imageType = IMAGE_TYPES.find((t) => t === media.mediaType) ?? "image/jpeg"; // WhatsApp/Telegram фото почти всегда jpeg
    lastContent = isPdf
      ? [
          { type: "document", source: { type: "base64", media_type: "application/pdf", data: media.data } },
          { type: "text", text: "Пациент прислал этот документ." },
        ]
      : [
          { type: "image", source: { type: "base64", media_type: imageType, data: media.data } },
          { type: "text", text: "Пациент прислал это фото." },
        ];
  } else {
    const clientText = String(lastInbound.text ?? conv.lastMessagePreview ?? "").trim();
    if (!clientText || clientText.startsWith("[")) return; // другое медиа без текста — подсказывать нечего
    lastContent = clientText.slice(0, 2000);
  }

  const history = toAlternating(histDesc);
  if (history.length > 0) history[history.length - 1]!.content = lastContent; // реальные данные вместо «[фото]»
  if (history.length === 0) history.push({ role: "user", content: lastContent });

  // Только НОВЫЙ клиент — то же правило, что у обычного автоответа.
  // На тестовом номере это условие не действует.
  if (!isTestChat) {
    const first = await db()
      .collection("messages")
      .where("conversationId", "==", chatId)
      .orderBy("createdAt", "asc")
      .limit(1)
      .get();
    const firstAt = (first.docs[0]?.data()?.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? Date.now();
    if (Date.now() - firstAt > 10 * 60_000) return;
  }

  const digits = String(conv.phone ?? chatId).replace(/\D/g, "");
  const byPhone: "kz" | "other" = countryByPhone(digits) === "kz" ? "kz" : "other";
  const said = citizenFromChat(
    histDesc.filter((m) => m.direction === "inbound").map((m) => String(m.text ?? "")),
  );
  // Порядок важен: свежие слова пациента > то, что уже выяснили в этом чате
  // раньше (окно истории всего 16 сообщений, сказанное давно из него ушло) >
  // код номера как последняя догадка.
  const stored = conv.aiCountry === "kz" || conv.aiCountry === "other" ? (conv.aiCountry as "kz" | "other") : null;
  const guess = said ?? stored ?? byPhone;

  try {
    const qr = await quickReplyKnowledge();
    const out = await replyWithCountryCheck(qr, guess, autoSend, pickModel(cfg.model), history);
    const text = out?.text;
    if (!text) return;
    // Страна пациента видна менеджеру в карточке и не пересчитывается заново
    // на каждое сообщение — если человек один раз сказал, что он из России,
    // это уже про весь чат, а не про одну реплику.
    if (out.country !== conv.aiCountry) await convRef.set({ aiCountry: out.country }, { merge: true });

    if (!autoSend) {
      await convRef.set({ aiSuggestion: text, aiSuggestionAt: ts() }, { merge: true });
      return;
    }

    // Автоотправка: помечаем ДО реальной отправки — если сеть/API дважды
    // дёрнут эту функцию почти одновременно, второй вызов упрётся в
    // 8-секундный кулдаун выше и не продублирует сообщение.
    await convRef.set({ aiSuggestionAt: ts() }, { merge: true });
    if (chatId.startsWith("tg_")) {
      if (!tgToken) return; // вызвано не из телеграм-обработчика — послать нечем
      const tgChatId = chatId.replace(/^tg_/, "");
      const sent = await tgSendTextApi(tgToken, { chatId: Number(tgChatId), text });
      await db()
        .collection("messages")
        .doc(`tg_${tgChatId}_${sent.message_id}`)
        .set({
          conversationId: chatId,
          chatId,
          tgMessageId: sent.message_id,
          direction: "outbound",
          type: "text",
          text,
          status: "sent",
          authorId: "auto",
          aiGenerated: true,
          createdAt: ts(),
        });
      await convRef.set(
        {
          lastMessageAt: ts(),
          lastMessagePreview: text.slice(0, 120),
          lastOutbound: true,
          lastAuthorId: "auto",
          lastAuthorName: null,
          updatedAt: ts(),
        },
        { merge: true },
      );
    } else {
      // WhatsApp — через общую очередь: та же пауза и статус в переписке,
      // что и у остальных автосообщений.
      await enqueue({
        kind: "text",
        chatId,
        text,
        authorId: "auto",
        crmMessageId: randomUUID(),
        reason: "delay",
        autoReply: true,
        nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + 3000),
      });
    }
  } catch (e) {
    console.error("aiReply fail", chatId, String(e instanceof Error ? e.message : e));
  }
}

/** Прогон без привязки к реальному чату — проверить ключ/промпт из консоли. */
export async function aiTestReply(text: string, citizen: "kz" | "other", autoSend = true): Promise<{ страна: string; ответ: string; модель: string }> {
  const qr = await quickReplyKnowledge();
  const cfg = (await db().doc("config/aiReply").get()).data() ?? {};
  const model = pickModel(cfg.model);
  const out = await replyWithCountryCheck(qr, citizen, autoSend, model, [{ role: "user", content: text.slice(0, 2000) }]);
  return { страна: out?.country ?? citizen, ответ: out?.text ?? "", модель: model };
}
