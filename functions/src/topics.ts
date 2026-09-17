/**
 * Тема обращения по тексту клиента.
 *
 * Тем три: «обучение» (доктор учит специалистов), «БАДы» (заказ добавок) и
 * «звонок» (клиент просит перезвонить/созвониться). У каждой своя вкладка в
 * приложении — такие обращения не должны мешаться в потоке пациентов. Метка
 * ставится ТОЛЬКО на входящие и только вперёд: старую переписку не
 * переразмечаем.
 *
 * Обучение и звонок ловим по корню слова: «обучен» → «обучению», «обучаться»;
 * «звон» → «звонок», «позвоните», «перезвоню», «созвониться» — и заодно
 * опечатки в окончании («позвонте», «перзвоните»), потому что корень
 * посередине слова обычно цел, даже если конец опечатан. БАДы — по фразам
 * целиком: «бад» слишком короткий и частый кусок строки («бадминтон»),
 * поэтому ждём осмысленное предложение вроде «хочу заказать бады».
 */
import * as admin from "firebase-admin";

const db = () => admin.firestore();

/// Умолчания. Правятся в config/topics без деплоя:
/// trainingKeywords/callKeywords — корни слов, supplementPhrases — фразы целиком.
const DEFAULT_TRAINING = ["обучен", "обуча", "стажиров"];
const DEFAULT_SUPPLEMENTS = [
  "хочу заказать бады",
  "хочу заказать бад",
  "хочу купить бады",
  "хочу купить бад",
  "хочу приобрести бады",
  "интересуют бады",
  "по поводу бадов",
  "по поводу бад",
  "заказать добавки",
  "заказать витамины",
];
// ЦЕЛЫМИ СЛОВАМИ, а не корнем «звон». Корень ловил ЛЮБОЕ упоминание звонка,
// включая рассказ о прошлом («я вам звонила, но не дозвонилась», «мне звонили
// с вашего номера») — и чаты улетали в раздел «Звонок» без всякой просьбы
// позвонить. Здесь только формы-просьбы: повелительные и «хочу/можно
// позвонить». Прошедшее время («звонил», «дозвонился») в список не входит и
// теперь не срабатывает.
//
// Запись с «*» на конце — корень, ищется куском строки. Нужна для казахского:
// там к корню липнут суффиксы («хабарласыңыз», «хабарласыңызшы»), а сами
// корни «қоңырау» и «хабарлас» в посторонних словах не встречаются.
const DEFAULT_CALL = [
  // просьба позвонить
  "позвоните", "позвонить", "позвони", "позвоню",
  "перезвоните", "перезвонить", "перезвони", "перезвоню",
  "созвониться", "созвонимся", "созвонится",
  "наберите", "набери",
  "звонок", "звонка",
  // частые опечатки тех же форм
  "позвонте", "позвонити", "пазвоните", "перзвоните", "перезвонте",
  // казахский: корнем, из-за суффиксов
  "қоңырау*", "хабарлас*",
];

type Rules = { training: string[]; supplements: string[]; call: string[] };

let cache: { rules: Rules; at: number } | null = null;

/**
 * Общий вид текста: регистр, «ё», знаки препинания и лишние пробелы значения
 * не имеют. «Здравствуйте! Хочу ЗАКАЗАТЬ БАДы.» → «здравствуйте хочу заказать бады».
 */
export function normalizeTopicText(s: string): string {
  return (s ?? "")
    .toLowerCase()
    .replace(/ё/g, "е")
    .replace(/[^a-zа-я0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

/**
 * То же приведение к общему виду, но БЕЗ потери букв других алфавитов.
 *
 * normalizeTopicText оставляет только a-z и а-я, и казахские буквы (ө, қ, ұ,
 * ә, і, ң, ғ, ү) в нём просто исчезают: «қанша» превращается в «анша».
 * Для тем это терпимо, а там, где от разбора зависит ответ клиенту или
 * деньги, — нет.
 */
export function normalizeAnyScript(s: string): string {
  return (s ?? "")
    .toLowerCase()
    .replace(/ё/g, "е")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()
    .replace(/\s+/g, " ");
}

/**
 * Нормализация правила с сохранением хвостовой «*».
 *
 * normalizeAnyScript вычищает всё, кроме букв и цифр, — вместе с «*». Без
 * этой обёртки маркер корня («хабарлас*») молча терялся бы при загрузке, и
 * правило превращалось в поиск целого слова, которое в казахском почти
 * никогда не встречается без суффикса.
 */
function normalizeRule(s: string): string {
  const isRoot = s.trimEnd().endsWith("*");
  const norm = normalizeAnyScript(s);
  return isRoot ? `${norm}*` : norm;
}

function listFrom(v: unknown): string[] {
  const raw = Array.isArray(v) ? v : [];
  return raw.map((w) => normalizeRule(String(w))).filter((w) => w.replace("*", "").length >= 3);
}

async function rules(): Promise<Rules> {
  if (cache && Date.now() - cache.at < 5 * 60_000) return cache.rules;
  const out: Rules = {
    training: DEFAULT_TRAINING,
    supplements: DEFAULT_SUPPLEMENTS.map(normalizeAnyScript),
    call: DEFAULT_CALL.map(normalizeRule),
  };
  try {
    const d = (await db().doc("config/topics").get()).data();
    const t = listFrom(d?.trainingKeywords);
    const s = listFrom(d?.supplementPhrases);
    const c = listFrom(d?.callKeywords);
    if (t.length > 0) out.training = t;
    if (s.length > 0) out.supplements = s;
    if (c.length > 0) out.call = c;
  } catch {
    /* нет конфига — работаем на умолчаниях */
  }
  cache = { rules: out, at: Date.now() };
  return out;
}

/** Фраза найдена: одно слово ищем целым словом, фразу — куском текста. */
function hit(text: string, phrase: string): boolean {
  if (!phrase.includes(" ")) return ` ${text} `.includes(` ${phrase} `);
  return text.includes(phrase);
}

/** То же, но «слово*» означает корень — ищется куском строки (см. DEFAULT_CALL). */
function hitOrRoot(text: string, phrase: string): boolean {
  if (phrase.endsWith("*")) return text.includes(phrase.slice(0, -1));
  return hit(text, phrase);
}

/**
 * Тема входящего сообщения: 'training', 'supplements', 'call' или null.
 *
 * Разбор — через normalizeAnyScript (не normalizeTopicText): та версия
 * вырезает казахские буквы (ң, қ, ғ, ұ, і, ө, ә) начисто, и «қоңырау»
 * превращалось бы в мусор, который никогда ни с чем не совпадёт.
 *
 * Обучение проверяем первым: «хочу на обучение по БАДам» — это ученик.
 * «Звонок» — последним: это не отдельный продукт, а способ связи, поэтому
 * если сообщение явно про обучение или БАДы, тема остаётся их темой.
 */
export async function detectTopic(text: string): Promise<string | null> {
  const t = normalizeAnyScript(text);
  if (t.length < 3) return null;
  const r = await rules();
  if (r.training.some((w) => t.includes(w))) return "training";
  if (r.supplements.some((p) => hit(t, p))) return "supplements";
  // Тема «звонок» больше не назначается (раздел убран 2026-09-06): просьба
  // перезвонить — обычный пациентский чат. Правила r.call остаются в базе
  // только для диагностики.
  return null;
}

/** Темы, у которых своя вкладка: пациентские автоответы им не отправляем. */
export function isOwnTabTopic(topic: unknown): topic is string {
  return topic === "training" || topic === "supplements";
}

/** Показать текущие правила (для диагностики). */
export async function topicRules(): Promise<Rules> {
  return rules();
}
