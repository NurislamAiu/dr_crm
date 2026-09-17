/**
 * Уникализация повторяющихся текстов (WhatsApp).
 *
 * WhatsApp банит номер, когда один и тот же текст уходит многим клиентам —
 * именно так выглядят сохранённые быстрые ответы. Пока в WABA нет одобренных
 * шаблонов Meta, защищаемся иначе: первому клиенту текст уходит как есть, а
 * каждому следующему — слегка иначе (приветствие, эмодзи, пунктуация,
 * перенос строки). Смысл и тон не меняются.
 *
 * Применяется ТОЛЬКО к повторам: живая переписка своими словами не трогается.
 */
import * as admin from "firebase-admin";
import { fingerprint } from "./risk";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

/** Сколько помним отпечатки текстов канала. */
const SEEN_WINDOW_MS = 24 * 60 * 60 * 1000;
const SEEN_KEEP = 400;
const SEEN_DOC = "riskState/_texts";

type Seen = { h: string; c: string; t: number };

/**
 * Уходил ли ЭТОТ текст другим клиентам за последние сутки. Заодно
 * записывает текущую отправку. Транзакция — два менеджера могут слать
 * один шаблон одновременно.
 */
export async function textRepeats(text: string, chatId: string): Promise<boolean> {
  const h = fingerprint(text);
  const ref = db().doc(SEEN_DOC);
  try {
    return await db().runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const now = Date.now();
      const items = ((snap.data()?.items ?? []) as Seen[]).filter(
        (r) => r && typeof r.t === "number" && now - r.t < SEEN_WINDOW_MS,
      );
      // Повтор = тот же текст, но ДРУГОЙ чат (дважды одному человеку —
      // это переписка, а не рассылка).
      const repeat = items.some((r) => r.h === h && r.c !== chatId);
      items.push({ h, c: chatId, t: now });
      tx.set(ref, { items: items.slice(-SEEN_KEEP), updatedAt: ts() }, { merge: true });
      return repeat;
    });
  } catch {
    return false; // сбой учёта не должен блокировать отправку
  }
}

/**
 * Готовый вариант сохранённого быстрого ответа.
 *
 * Менеджер в приложении видит ОДИН текст — как и раньше. Сервер хранит рядом
 * с ним 5–6 равнозначных вариантов (поле variants у quickReplies) и при
 * отправке берёт случайный, но не тот, что использовал в прошлый раз. Так
 * один и тот же шаблон уходит разным клиентам по-разному.
 *
 * null — текст не из быстрых ответов (живая переписка) либо варианты
 * устарели после правки текста.
 */
export async function pickQuickReplyVariant(text: string): Promise<string | null> {
  const fp = exactFingerprint(text);
  const list = await quickReplies();
  const qr = list.find((q) => q.fp === fp && q.variantsFor === q.fp && q.variants.length > 0);
  if (!qr) return null;

  // Пул = оригинал + варианты: оригинал тоже иногда уходит, он лучший.
  // Варианты, потерявшие факты (адрес, ссылку, цену), в пул не берём — даже
  // если они как-то попали в базу раньше.
  const pool = [text, ...qr.variants.filter((v) => keepsFacts(text, v))];
  try {
    return await db().runTransaction(async (tx) => {
      const ref = db().doc("riskState/_variants");
      const snap = await tx.get(ref);
      const state = (snap.data()?.last ?? {}) as Record<string, number>;
      const last = typeof state[qr.id] === "number" ? state[qr.id]! : -1;
      let idx = Math.floor(Math.random() * pool.length);
      if (pool.length > 1 && idx === last) idx = (idx + 1) % pool.length;
      tx.set(ref, { last: { ...state, [qr.id]: idx }, updatedAt: ts() }, { merge: true });
      return pool[idx] ?? text;
    });
  } catch {
    return pool[Math.floor(Math.random() * pool.length)] ?? text;
  }
}

/**
 * Вариант обязан сохранить факты исходного текста: все ссылки и все числа
 * (адрес, номер дома, цены, даты). Если что-то потерялось — отправляем
 * оригинал. Страховка от повторения истории, когда из отправленного текста
 * пропадал адрес клиники.
 */
export function keepsFacts(original: string, variant: string): boolean {
  const nums = (s: string) => (s.match(/\d+/g) ?? []).slice().sort().join(",");
  const urls = (s: string) =>
    (s.match(/https?:\/\/\S+/gi) ?? []).map((u) => u.replace(/[.,;!?]+$/, "")).sort().join(",");
  return nums(original) === nums(variant) && urls(original) === urls(variant);
}

/**
 * Отпечаток ТОЧНОГО текста (цифры и знаки на месте).
 *
 * Отпечаток из risk.ts для этого не годится: он выбрасывает цифры и оставляет
 * последние 40 букв — по нему «Адрес: Астана, Калдаякова 13» совпадал с
 * шаблоном «Адрес клиники», и сервер подменял написанный менеджером адрес
 * заготовленным вариантом (пропадал дом, улица, свежая правка шаблона).
 * Подменять текст можно, только если менеджер отправил шаблон СЛОВО В СЛОВО.
 */
export function exactFingerprint(text: string): string {
  const norm = text.replace(/\s+/g, " ").trim();
  let h = 5381;
  for (let i = 0; i < norm.length; i++) h = ((h << 5) + h + norm.charCodeAt(i)) | 0;
  return `${norm.length.toString(36)}_${(h >>> 0).toString(36)}`;
}

type QuickReply = { id: string; fp: string; variants: string[]; variantsFor: string };

let qrCache: { v: QuickReply[]; at: number } | null = null;

/** Быстрые ответы с вариантами (кэш на минуту — коллекция маленькая). */
async function quickReplies(): Promise<QuickReply[]> {
  if (qrCache && Date.now() - qrCache.at < 60_000) return qrCache.v;
  let v: QuickReply[] = [];
  try {
    const snap = await db().collection("quickReplies").limit(200).get();
    v = snap.docs.map((d) => {
      const x = d.data();
      return {
        id: d.id,
        fp: exactFingerprint(String(x.text ?? "")),
        variants: ((x.variants ?? []) as unknown[]).filter((s): s is string => typeof s === "string" && s.length > 0),
        variantsFor: String(x.variantsFor ?? ""),
      };
    });
  } catch {
    v = [];
  }
  qrCache = { v, at: Date.now() };
  return v;
}

// ── Генератор «случайности», привязанный к чату ───────────────────────────

function seedOf(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

/** Детерминированный PRNG: одному чату — стабильный вариант текста. */
function rng(seed: number): () => number {
  let a = seed || 1;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const pick = <T>(arr: T[], r: () => number): T => arr[Math.floor(r() * arr.length)] ?? arr[0]!;

// ── Словари замен ─────────────────────────────────────────────────────────

/** Приветствия: меняем только если текст с него начинается. */
const GREETINGS = [
  "Здравствуйте",
  "Добрый день",
  "Здравствуйте 🙌",
  "Приветствую",
  "Добрый день 🙂",
];
const RE_GREETING = /^(здравствуйте|добрый день|доброе утро|добрый вечер|приветствую|привет)([!,.\s]|$)/i;

/** Взаимозаменяемые эмодзи — смысл тот же, символ другой. */
const EMOJI_SWAP: Record<string, string[]> = {
  "✅": ["✅", "✔️", "☑️"],
  "❌": ["❌", "⛔", "🚫"],
  "📱": ["📱", "☎️", "📞"],
  "ℹ️": ["ℹ️", "📌", "📋"],
  "📋": ["📋", "📝", "🗒"],
  "🌍": ["🌍", "🌎", "🌐"],
  "🙂": ["🙂", "😊", "☺️"],
};

/** Нейтральные концовки — добавляются не всегда. */
const TAILS = ["", "", "", "\n\nБудем рады помочь!", "\n\nЖдём вас!", "\n\nХорошего дня!"];

/**
 * Слегка меняет текст, сохраняя смысл. Вариант стабилен для одного чата
 * (повторная отправка тому же человеку не «мигает» формулировками).
 */
export function uniquifyText(text: string, chatId: string): string {
  // addWords: false — менеджер печатал этот текст руками, дописывать к нему
  // «Ждём вас!» или менять приветствие нельзя. Остаются только незаметные
  // отличия: неразрывный пробел, тире, эмодзи-синонимы, маркеры списка.
  return variantWithSeed(text, seedOf(`${chatId}|${text.length}|${Math.floor(Date.now() / 3600_000)}`), false);
}

/**
 * Готовит N различающихся вариантов одного текста — их сервер хранит рядом с
 * быстрым ответом и потом шлёт по кругу. Смысл, структура и цифры не
 * меняются: только приветствие, эмодзи-синонимы, пунктуация и концовка.
 */
export function makeVariants(text: string, n = 6): string[] {
  const out: string[] = [];
  const seen = new Set<string>([text.trimEnd()]);
  for (let seed = 1; seed <= 600 && out.length < n; seed++) {
    // Заготовленные варианты сохранённого ответа — можно и приветствие, и
    // концовку: их видно заранее, менеджер ничего не печатал.
    const v = variantWithSeed(text, seed * 2654435761, true);
    if (seen.has(v)) continue;
    // Вариант без адреса/ссылки/цены — брак, в базу не кладём.
    if (!keepsFacts(text, v)) continue;
    seen.add(v);
    out.push(v);
  }
  return out;
}

/**
 * @param addWords разрешено ли менять слова (приветствие) и дописывать
 *   концовку. Для заготовленных вариантов — да, для текста, который менеджер
 *   набрал руками, — нет.
 */
function variantWithSeed(text: string, seed: number, addWords: boolean): string {
  const r = rng(seed);
  let out = text;

  // Слои 1–6 меняют текст ВИДИМО (приветствие, эмодзи, знаки, концовка).
  // Они допустимы только для заготовленных вариантов быстрого ответа.
  // Текст, который менеджер набрал руками, уходит слово в слово — иначе к
  // живому вопросу приписывалось «Ждём вас!».
  if (addWords) {
    // 1. Приветствие в начале — на равнозначное.
    const m = out.match(RE_GREETING);
    if (m) {
      const tail = m[2] ?? "";
      out = pick(GREETINGS, r) + tail + out.slice(m[0].length);
    }

    // 2. Эмодзи — на синоним (первое вхождение каждого вида).
    for (const [base, variants] of Object.entries(EMOJI_SWAP)) {
      if (!out.includes(base)) continue;
      const to = pick(variants, r);
      if (to !== base) out = out.replace(base, to);
    }

    // 3. Пунктуация первой строки: «!» ↔ «.» (лёгкая смена интонации).
    if (r() < 0.5) {
      out = out.replace(/^([^\n]{1,80}?)!(\s|$)/, (_s, head: string, sp: string) => `${head}.${sp}`);
    }

    // 4. Маркеры списков: •, –, — (у текстов без приветствия и эмодзи это
    // главный источник различий).
    if (/^[\s]*[•–—-]\s/m.test(out)) {
      const bullet = pick(["•", "–", "—"], r);
      out = out.replace(/^([ \t]*)[•–—-](\s)/gm, (_s, pad: string, sp: string) => `${pad}${bullet}${sp}`);
    }

    // 5. Типографика: длинное тире ↔ среднее, «...» ↔ «…».
    if (r() < 0.5) out = out.replace(/ — /g, " – ");
    if (r() < 0.5) out = out.replace(/\.\.\./g, "…");

    // 6. Концовка — иногда добавляем нейтральную фразу.
    const tail = pick(TAILS, r);
    if (tail && !out.includes(tail.trim())) out = out.trimEnd() + tail;
  }

  // 7. Неразрывный пробел вместо обычного в одном месте. Глазу не видно,
  // но сообщение перестаёт совпадать с предыдущим побайтово.
  // ВАЖНО: хвостовые пробелы и переносы для этого не годятся — WhatsApp их
  // обрезает, текст возвращается к исходному, и эхо не склеивается с нашим
  // сообщением (в чате появлялся дубль).
  const spaces: number[] = [];
  for (let i = 1; i < out.length - 1; i++) if (out[i] === " ") spaces.push(i);
  if (spaces.length >= 1) {
    const at = spaces[Math.floor(r() * spaces.length)]!;
    out = `${out.slice(0, at)} ${out.slice(at + 1)}`;
  }

  return out.trimEnd();
}
