/**
 * Автоответчик по обучению — отвечает ученикам готовыми текстами раздела
 * «Обучение · …» из быстрых ответов.
 *
 * Сделан нарочно дешёвым, в два слоя:
 *
 *  1. Разбор по ключевым словам — БЕСПЛАТНО, без единого обращения к модели.
 *     Вопросы учеников очень однотипны («сколько стоит», «где проходит»,
 *     «когда старт»), и такие ловятся словарём. Правило строгое: отвечаем,
 *     только если подошёл РОВНО ОДИН раздел. Ноль совпадений или сразу
 *     несколько — значит вопрос не такой простой, каким кажется, и угадывать
 *     нельзя: неверный ответ про обучение за 2 000 000 ₸ дороже любых токенов.
 *
 *  2. Claude Haiku 4.5 — только когда словарь не справился. Модели уходит
 *     ОДИН маленький раздел «Обучение» (~1500 токенов), а обратно она отдаёт
 *     лишь ЗАГОЛОВОК готового ответа, а не его текст: выхода почти нет, и
 *     платить не за что. Текст подставляем сами из базы — дословно.
 *
 * Кэширование промпта здесь бесполезно: минимум для кэша у Haiku 4.5 —
 * 4096 токенов, наш промпт вдвое короче и просто не закэшируется.
 *
 * config/trainingReply: enabled, testPhone (обкатка на одном номере),
 * autoSend (отвечать самому, а не готовить черновик).
 */
import * as admin from "firebase-admin";
import { randomUUID } from "crypto";
import Anthropic from "@anthropic-ai/sdk";
import { ANTHROPIC_API_KEY } from "./ai-reply";
import { normalizePhone, recentMessages, toAlternating } from "./chat-context";

import { enqueue } from "./limits";
import { QuickReply, trainingKnowledge } from "./quick-replies";
import { normalizeAnyScript } from "./topics";
import { autoReplyStillNeeded } from "./wa-autoreply";
import { uniquifyText } from "./variate";
import { tgSendTextApi } from "./telegram/api";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

/** Дешёвая модель специально: разбираем короткий вопрос по короткому разделу. */
const MODEL = "claude-haiku-4-5";

// ── Слой 1: словарь ────────────────────────────────────────────────────────
/**
 * Заголовок раздела → слова, по которым он однозначно узнаётся. Слова ищутся
 * корнями по нормализованному тексту («Сколько СТОИТ?» → «сколько стоит»),
 * поэтому «стоим» ловит и «стоимость», и «стоимости».
 *
 * Порядок в списке значения не имеет — при попадании в два раздела сразу мы
 * всё равно уходим к модели.
 */
const ROUTES: { title: string; words: string[] }[] = [
  {
    title: "Обучение · стоимость",
    // «рассрочки» тут намеренно нет: в готовом тексте про неё ни слова, и
    // отправить в ответ прайс — значит не ответить. Такой вопрос уходит
    // модели, которая честно скажет, что уточним.
    words: ["сколько стоит", "скок стоит", "стоить", "стоимост", "цена", "цену", "цены", "почем", "по чем", "прайс", "предоплат", "оплат", "қанша", "канша", "неше тенге", "бағасы"],
  },
  { title: "Обучение · адрес", words: ["где проход", "где буд", "адрес", "какой город", "в каком город", "куда прие", "как добрат"] },
  { title: "Обучение · даты старта", words: ["когда старт", "когда начал", "когда начин", "дата старт", "даты старт", "когда поток", "когда групп"] },
  { title: "Обучение · как подать заявку", words: ["как подат", "как записат", "как попаст", "где анкет", "ссылк на анкет", "как оставит заявк"] },
  { title: "Обучение · после анкеты", words: ["заполнил анкет", "заполнила анкет", "отправил анкет", "отправила анкет", "анкету заполнил", "анкету отправил"] },
  { title: "Обучение · кому подходит", words: ["кому подход", "без опыт", "нет опыт", "не врач", "нужно ли образован", "подойдет ли мне", "подойду ли"] },
  { title: "Обучение · что даёт", words: ["что дает", "что вход", "что получ", "сертификат", "чему учат", "программ обучен"] },
];

/**
 * Заголовок готового ответа по тексту вопроса — или null, если однозначно не
 * определилось. null означает «спросить модель», а не «промолчать».
 */
export function routeByKeywords(text: string): string | null {
  const t = normalizeAnyScript(text);
  if (t.length < 3) return null;
  const hits = ROUTES.filter((r) => r.words.some((w) => t.includes(w)));
  return hits.length === 1 ? hits[0]!.title : null;
}

/// Разговор закончен: благодарность, отказ, «подумаю». Отвечать не на что.
const CLOSERS = [
  "спасибо", "благодар", "подумаю", "буду думать", "откажус", "отказыва",
  "не надо", "ненадо", "не нужно", "ненужно", "понятно", "все ясно", "ясно",
  "хорошо", "ладно", "договорились", "пока нет", "пока не готов", "рахмет", "жарайды",
];
/// Просьба созвониться: телефона в текстах нет, и звонок — дело менеджера.
const CALL_WORDS = ["созвон", "позвон", "перезвон", "наберите", "номер телефон", "свяжитесь со мной", "можно ваш номер"];
/// Возражение по цене — это продажа, а не справка: повторить прайс значит не ответить.
const PRICE_OBJECTIONS = ["дорого", "дороговат", "не по карману", "дешевле", "скидк", "торг"];
/// Признаки, что человек спрашивает про ЛЕЧЕНИЕ, а не про обучение.
const PATIENT_WORDS = ["прием", "приема", "приемы", "лечен", "лечит", "грыж", "болит", "боли", "спина", "спину", "сустав", "мрт"];
const TRAINING_WORDS = ["обучен", "обуча", "учеб", "курс", "группу", "группа", "поток", "анкет", "стажиров"];

/**
 * Причина промолчать — или null, если отвечать можно.
 *
 * Два случая, где автоответ вредит:
 *
 * 1. Человек прощается или отказывается («спасибо, подумаю», «мне не надо»).
 *    Ответ на это — навязчивость, а не сервис. Отсекаем только короткие
 *    реплики без вопроса: «спасибо, а когда старт?» — это всё ещё вопрос.
 *
 * 2. В чате обучения спрашивают про приём у врача («сколько стоит приём?»).
 *    Словарь видит «сколько стоит» и уверенно отдаёт прайс ОБУЧЕНИЯ на два
 *    миллиона — человеку, который спросил про приём за 95 000. Такие письма
 *    отдаём менеджеру: тут сменилась тема, а не вопрос уточнился.
 */
export function skipReason(text: string): string | null {
  const t = normalizeAnyScript(text);
  if (t.length < 2) return "пустое сообщение";

  const asksSomething = /[?]/.test(text) || /\b(как|где|когда|сколько|что|какой|какая|каком|можно|ли|почему)\b/.test(t);
  if (!asksSomething && t.length <= 60 && CLOSERS.some((w) => t.includes(w))) {
    return "прощание или отказ — отвечать не на что";
  }

  if (CALL_WORDS.some((w) => t.includes(w))) return "просит созвониться — менеджеру";
  if (PRICE_OBJECTIONS.some((w) => t.includes(w))) return "возражение по цене — менеджеру";

  const patient = PATIENT_WORDS.some((w) => t.includes(w));
  const training = TRAINING_WORDS.some((w) => t.includes(w));
  if (patient && !training) return "вопрос про приём, а не про обучение — менеджеру";

  return null;
}

// ── Слой 2: модель ─────────────────────────────────────────────────────────
const NO_MATCH = "__none__";

/**
 * Модель НЕ пишет текст — она только ВЫБИРАЕТ готовый ответ по заголовку.
 * Своих формулировок у бота нет вообще: нет подходящего шаблона — молчим и
 * отдаём чат менеджеру. Так бот физически не может ничего выдумать (а он уже
 * пробовал: сочинял имя собеседника, курс валют и фразы про «материалы»),
 * и ответ стоит копейки — на выходе один заголовок, а не абзац текста.
 */
function buildTool(qr: QuickReply[]): Anthropic.Tool {
  return {
    name: "reply",
    description: "Выбрать готовый ответ клиники, который полностью закрывает вопрос собеседника.",
    input_schema: {
      type: "object",
      properties: {
        quick_reply_title: {
          type: "string",
          enum: [...qr.map((q) => q.title), NO_MATCH],
          description: `Точный заголовок готового ответа, который ПОЛНОСТЬЮ отвечает на вопрос. "${NO_MATCH}", если ни один не подходит целиком.`,
        },
      },
      required: ["quick_reply_title"],
    },
  };
}

function buildSystemPrompt(qr: QuickReply[]): string {
  return [
    "Человек пишет в мессенджер клиники остеопатии Dr. Toitayev (Астана) по поводу ОБУЧЕНИЯ у доктора Тойтаева.",
    "Твоя единственная задача — выбрать из готовых ответов клиники тот, который ПОЛНОСТЬЮ отвечает на его последнее сообщение, и назвать его заголовок через инструмент reply.",
    "",
    "ПРАВИЛА:",
    "1. Свой текст писать нельзя. Ты только выбираешь заголовок из списка.",
    `2. Если ни один готовый ответ не закрывает вопрос ЦЕЛИКОМ — отвечай "${NO_MATCH}". Так бывает часто, и это нормальный ответ: чат возьмёт живой менеджер.`,
    `3. Лучше "${NO_MATCH}", чем «примерно подходящий» ответ. Прислать человеку текст не про то, что он спросил, — хуже, чем промолчать.`,
    "4. Понимай сообщения на любом языке — русском, казахском, английском: язык вопроса на выбор заголовка не влияет.",
    "5. Смотри на ПОСЛЕДНЕЕ сообщение — предыдущие нужны только чтобы понять его смысл.",
    "",
    "ГОТОВЫЕ ОТВЕТЫ (заголовок и текст):",
    qr.map((q) => `### ${q.title}\n${q.text}`).join("\n\n"),
  ].join("\n");
}

/** Выбранный моделью заголовок готового ответа. null = подходящего нет. */
async function runModel(qr: QuickReply[], messages: Anthropic.MessageParam[]): Promise<string | null> {
  const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY.value() });
  const res = await client.messages.create({
    model: MODEL,
    max_tokens: 100,
    system: buildSystemPrompt(qr),
    tools: [buildTool(qr)],
    tool_choice: { type: "tool", name: "reply" },
    messages,
  });
  const use = res.content.find((b): b is Anthropic.ToolUseBlock => b.type === "tool_use");
  const title = String((use?.input as { quick_reply_title?: string } | undefined)?.quick_reply_title ?? "").trim();
  if (!title || title === NO_MATCH) return null; // нет шаблона — молчим
  return qr.some((q) => q.title === title) ? title : null;
}

/**
 * Какой готовый ответ отправить — сначала бесплатным словарём, потом моделью.
 *
 * sentTitles — что этому чату уже отправляли: такие шаблоны выкидываются из
 * выбора целиком. Человеку, которому прайс уже приходил, второй раз тот же
 * прайс не нужен — это не ответ, а спам. Модель повтор выбрать не может
 * физически: его нет в списке, который ей дают.
 */
async function pickReply(
  qr: QuickReply[],
  sentTitles: string[],
  question: string,
  history: () => Promise<Anthropic.MessageParam[]>,
): Promise<{ title: string; text: string; layer: string } | null> {
  // Выбор идёт по ПОЛНОМУ списку, а отправленное отсекается уже после.
  // Убирать отправленное из списка заранее — заманчиво, но вредно: модель
  // тогда берёт следующий по похожести шаблон, и человек, которому уже
  // отправили «как подать заявку», получает «кому подходит», а на «Да» —
  // приветствие. Промолчать здесь честнее: правильный ответ у человека уже
  // есть, дальше нужен живой менеджер, а не второй по релевантности текст.
  const routed = routeByKeywords(question);
  const title = routed ?? (await runModel(qr, await history()));
  if (!title) return null;
  if (sentTitles.includes(title)) return null; // этот текст сюда уже уходил
  const hit = qr.find((q) => q.title === title);
  return hit ? { title: hit.title, text: hit.text, layer: `${routed ? "словарь" : "модель"} → ${hit.title}` } : null;
}

/** Только буквы и цифры — чтобы сравнивать тексты, не спотыкаясь об оформление. */
function textKey(s: string): string {
  return s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "").slice(0, 60);
}

/**
 * Заголовки готовых ответов, которые в этот чат уже уходили.
 *
 * Считаем двумя способами и объединяем:
 *  — отметка trainingSentTitles, которую бот ставит при отправке;
 *  — сверка реально отправленных в чат текстов с базой шаблонов.
 *
 * Второе важнее, чем кажется. Оно закрывает и сообщения, отправленные до
 * появления отметки, и — главное — быстрые ответы, которые менеджер отправил
 * РУКАМИ: прислать человеку прайс следом за менеджером так же глупо, как
 * прислать его дважды самому. Сравниваем по буквам и цифрам, потому что
 * uniquifyText мог подменить пробелы и тире.
 */
function sentTitlesOf(conv: FirebaseFirestore.DocumentData, outbound: FirebaseFirestore.DocumentData[], qr: QuickReply[]): string[] {
  const stored = Array.isArray(conv.trainingSentTitles) ? conv.trainingSentTitles.map((x: unknown) => String(x)) : [];
  const keys = new Map(qr.map((q) => [textKey(q.text), q.title]));
  const seen = new Set<string>(stored);
  for (const m of outbound) {
    if (m.direction !== "outbound") continue;
    const t = typeof m.text === "string" ? m.text : "";
    if (!t) continue;
    const title = keys.get(textKey(t));
    if (title) seen.add(title);
  }
  return [...seen];
}

/** Самое свежее входящее чата — вместе с id, по нему сверяем «не устарели ли». */
async function latestInbound(chatId: string): Promise<FirebaseFirestore.QueryDocumentSnapshot | null> {
  const snap = await db()
    .collection("messages")
    .where("conversationId", "==", chatId)
    .orderBy("createdAt", "desc")
    .limit(10)
    .get();
  return snap.docs.find((d) => d.data().direction === "inbound") ?? null;
}

/**
 * Ответ ученику в чате chatId. Работает только с темой «обучение» — пациентов
 * ведёт свой сценарий (maybeAiSuggest), и наоборот.
 *
 * tgToken нужен только для отправки в Telegram; у WhatsApp своя очередь.
 */
export async function maybeTrainingReply(chatId: string, tgToken?: string): Promise<void> {
  const cfg = (await db().doc("config/trainingReply").get()).data() ?? {};
  if (cfg.enabled !== true) return;

  const convRef = db().doc(`conversations/${chatId}`);
  const conv = (await convRef.get()).data() ?? {};
  if (conv.blocked === true) return;
  if (conv.topic !== "training") return; // не ученик — не наш сценарий

  // Приветствие новому ученику отправляет обычный автоответ (в WhatsApp —
  // maybeWaAutoReply, он же идёт первым в обработчике; в Telegram — ответ на
  // /start). Если оно ушло только что, значит это то же самое первое
  // сообщение — второй текст следом выглядел бы спамом.
  //
  // Свежая отметка времени сама по себе НЕ значит, что приветствие ушло:
  // давним чатам maybeWaAutoReply ничего не шлёт, но метку всё равно
  // обновляет — каждый раз, на каждое входящее. Отличаем по waAutoReplySkip:
  // он стоит ровно там, где отправки не было. Без этой проверки автоответчик
  // молчал бы во всех давних чатах вообще.
  const greetedAt = (conv.waAutoReplyAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
  const greetingSent = greetedAt > 0 && !conv.waAutoReplySkip;
  if (greetingSent && Date.now() - greetedAt < 20_000) return;

  const testPhone = normalizePhone(cfg.testPhone);
  const isTestChat = testPhone.length > 0 && normalizePhone(conv.phone) === testPhone;
  if (testPhone.length > 0 && !isTestChat) return; // обкатка на одном номере
  // Автоотправка вне обкатки разрешена только явным флагом allChats: пока он
  // не выставлен, снятый testPhone означает «готовим черновики», а не «пиши
  // всем сам» — включить бота живым людям должно быть отдельным решением.
  const autoSend = cfg.autoSend === true && (isTestChat || cfg.allChats === true);

  const lastInboundDoc = await latestInbound(chatId);
  if (!lastInboundDoc) return;

  // Люди пишут очередями: «здравствуйте», «хочу на обучение», «сколько стоит»
  // — три сообщения за пять секунд. Отвечать на каждое значит завалить
  // человека тремя текстами подряд. Поэтому выжидаем паузу и отвечаем только
  // если за это время не пришло НОВОГО сообщения: обработчики более ранних
  // сообщений тихо выходят, отвечает последний — и сразу на всю очередь,
  // потому что вся она уходит модели как история переписки.
  const settleMs = Math.min(Math.max(Number(cfg.settleSec ?? 7) * 1000, 0), 60_000);
  if (settleMs > 0) await new Promise((r) => setTimeout(r, settleMs));

  const freshInbound = await latestInbound(chatId);
  if (!freshInbound || freshInbound.id !== lastInboundDoc.id) return; // пришло новое — ответит его обработчик

  // Менеджер успел ответить сам, пока мы ждали, — бот молчит (та же логика,
  // что у обычного автоответа в очереди WhatsApp).
  const inboundAt = (freshInbound.data().createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? Date.now();
  if (!(await autoReplyStillNeeded(chatId, inboundAt))) return;

  const snap = await db()
    .collection("messages")
    .where("conversationId", "==", chatId)
    .orderBy("createdAt", "desc")
    .limit(20)
    .get();
  const histDesc = snap.docs.map((d) => d.data());

  const question = String(freshInbound.data().text ?? "").trim();
  if (!question || question.startsWith("/")) return; // /start — на него уже ушло приветствие
  const skip = skipReason(question);
  if (skip) {
    console.log("trainingReply skip", chatId, skip);
    return;
  }

  // Право ответить занимается ОДНОЙ транзакцией и ДО обращения к модели:
  // вебхуки дублируются, и без этого клиент получает один и тот же текст
  // несколько раз подряд (ровно так и случилось у пациентского бота).
  const claimed = await db().runTransaction(async (tx) => {
    const fresh = (await tx.get(convRef)).data() ?? {};
    if (!autoSend && fresh.trainingSuggestion) return false; // прошлый черновик ещё не разобрали
    if (fresh.trainingClaimMsgId === freshInbound.id) return false; // на это сообщение уже отвечали
    const claimAt = (fresh.trainingClaimAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    if (Date.now() - claimAt < 8000) return false;
    tx.set(convRef, { trainingClaimAt: ts(), trainingClaimMsgId: freshInbound.id }, { merge: true });
    return true;
  });
  if (!claimed) return;

  try {
    const qr = await trainingKnowledge();
    if (qr.length === 0) return;

    // Слой 1 (словарь) бесплатный, слой 2 (модель) — только если словарь не
    // дал однозначного ответа. Уже отправленные сюда шаблоны в выбор не идут.
    const picked = await pickReply(qr, sentTitlesOf(conv, histDesc, qr), question, async () => {
      const history = toAlternating(histDesc.slice(0, 10));
      if (history.length > 0) history[history.length - 1]!.content = question.slice(0, 1000);
      if (history.length === 0) history.push({ role: "user", content: question.slice(0, 1000) });
      return history;
    });
    if (!picked) return;
    const text = picked.text;

    if (!autoSend) {
      await convRef.set({ trainingSuggestion: text, trainingSuggestionAt: ts() }, { merge: true });
      return;
    }

    // Запоминаем ДО отправки: если сообщение уйдёт, а запись упадёт, повтор
    // этого же текста будет хуже, чем лишняя запись без отправки.
    await convRef.set(
      { trainingSentTitles: admin.firestore.FieldValue.arrayUnion(picked.title) },
      { merge: true },
    );

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
    console.error("trainingReply fail", chatId, String(e instanceof Error ? e.message : e));
  }
}

/**
 * Разбор накопившихся чатов обучения, оставшихся без ответа.
 *
 * Обычный сценарий срабатывает на входящее сообщение — те, кто написал ДО
 * запуска бота, так и висят неотвеченными. Здесь мы проходим по ним разово.
 *
 * По умолчанию только показывает, что ушло бы (dry=true): это отправка живым
 * людям, и увидеть текст заранее дешевле, чем извиняться потом.
 *
 * Отправка нарочно размазана во времени: одинаковый текст, ушедший в три
 * десятка чатов за минуту, — классическая причина бана номера WhatsApp
 * (см. флаг mass в limits.ts). Поэтому сообщения уходят с промежутком в
 * полминуты, а не пачкой.
 */
export async function trainingBacklog(opts: {
  dry: boolean;
  limit: number;
  hours: number;
  tgToken?: string;
}): Promise<{
  найдено: number;
  обработано: number;
  чаты: { чат: string; вопрос: string; слой: string; ответ: string; отправка: string }[];
  менеджеру: { чат: string; вопрос: string; причина: string }[];
}> {
  const qr = await trainingKnowledge();
  const snap = await db().collection("conversations").where("topic", "==", "training").limit(400).get();
  const since = Date.now() - opts.hours * 3600_000;

  const pending = snap.docs
    .map((d) => ({ id: d.id, data: d.data() }))
    .filter((c) => {
      if (c.data.blocked === true) return false;
      if (c.data.lastOutbound === true) return false; // на последнее сообщение уже ответили
      if (c.data.hasInbound !== true) return false;
      const at = (c.data.lastMessageAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      return at >= since;
    })
    .sort((a, b) => {
      const at = (x: (typeof a)["data"]) => (x.lastMessageAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      return at(b.data) - at(a.data);
    });

  const out: { чат: string; вопрос: string; слой: string; ответ: string; отправка: string }[] = [];
  const skipped: { чат: string; вопрос: string; причина: string }[] = [];
  let i = 0;
  for (const c of pending.slice(0, opts.limit)) {
    const last = await latestInbound(c.id);
    const question = String(last?.data().text ?? "").trim();
    if (!question || question.startsWith("/")) continue;
    const skip = skipReason(question);
    if (skip) {
      skipped.push({ чат: c.id, вопрос: question.slice(0, 90), причина: skip });
      continue;
    }

    const recent = await recentMessages(c.id, 20);
    const sent = sentTitlesOf(c.data, recent, qr);
    const picked = await pickReply(qr, sent, question, async () => {
      const history = toAlternating(recent.slice(0, 10));
      if (history.length > 0) history[history.length - 1]!.content = question.slice(0, 1000);
      if (history.length === 0) history.push({ role: "user", content: question.slice(0, 1000) });
      return history;
    });
    if (!picked) {
      skipped.push({
        чат: c.id,
        вопрос: question.slice(0, 90),
        причина: sent.length > 0 ? "подходящий шаблон уже отправляли — менеджеру" : "нет подходящего шаблона — менеджеру",
      });
      continue;
    }
    const text = picked.text;
    const layer = picked.layer;

    let how = "показ (без отправки)";
    if (!opts.dry) {
      // Полминуты между сообщениями: разом ушедший одинаковый текст — прямой
      // путь к бану номера.
      const delayMs = i * 30_000;
      if (c.id.startsWith("tg_")) {
        if (!opts.tgToken) continue;
        if (delayMs > 0) await new Promise((r) => setTimeout(r, 1500)); // Telegram: свой темп, лимит ~1 сообщение в секунду в чат
        const tgChatId = c.id.replace(/^tg_/, "");
        const sent = await tgSendTextApi(opts.tgToken, { chatId: Number(tgChatId), text });
        await db().collection("messages").doc(`tg_${tgChatId}_${sent.message_id}`).set({
          conversationId: c.id, chatId: c.id, tgMessageId: sent.message_id,
          direction: "outbound", type: "text", text, status: "sent",
          authorId: "auto", aiGenerated: true, createdAt: ts(),
        });
        await db().doc(`conversations/${c.id}`).set(
          { lastMessageAt: ts(), lastMessagePreview: text.slice(0, 120), lastOutbound: true, lastAuthorId: "auto", lastAuthorName: null, updatedAt: ts() },
          { merge: true },
        );
        how = "отправлено (Telegram)";
      } else {
        // Шестнадцать байт-в-байт одинаковых прайсов подряд — ровно то, по
        // чему WhatsApp вычисляет рассылку и банит номер. uniquifyText даёт
        // каждому чату свой вариант: неразрывный пробел, тире, маркеры
        // списка. Смысл, цифры и ссылки не меняются.
        await enqueue({
          kind: "text", chatId: c.id, text: uniquifyText(text, c.id), authorId: "auto",
          crmMessageId: randomUUID(), reason: "delay", autoReply: true,
          nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + 5000 + delayMs),
        });
        how = `в очереди, уйдёт через ${Math.round((5000 + delayMs) / 1000)} с`;
      }
      // Помечаем, чтобы обычный сценарий не ответил на это же сообщение второй
      // раз, и запоминаем шаблон — повторно он в этот чат уже не уйдёт.
      await db().doc(`conversations/${c.id}`).set(
        {
          trainingSentTitles: admin.firestore.FieldValue.arrayUnion(picked.title),
          ...(last ? { trainingClaimAt: ts(), trainingClaimMsgId: last.id } : {}),
        },
        { merge: true },
      );
      i++;
    }
    out.push({ чат: c.id, вопрос: question.slice(0, 90), слой: layer, ответ: text.slice(0, 90).replace(/\n/g, " / "), отправка: how });
  }
  return { найдено: pending.length, обработано: out.length, чаты: out, менеджеру: skipped };
}

/**
 * Прогон без чата — проверить из консоли, каким слоем разобрался вопрос.
 * Показывает, ушёл ли ответ бесплатно (словарь) или через модель.
 */
export async function trainingTestReply(text: string): Promise<{ слой: string; ответ: string }> {
  const qr = await trainingKnowledge();
  const routed = routeByKeywords(text);
  if (routed) {
    const hit = qr.find((q) => q.title === routed);
    if (hit) return { слой: `словарь (бесплатно) → ${routed}`, ответ: hit.text };
  }
  const out = await runModel(qr, [{ role: "user", content: text.slice(0, 1000) }]);
  return { слой: "модель (Haiku 4.5)", ответ: out ?? "" };
}
