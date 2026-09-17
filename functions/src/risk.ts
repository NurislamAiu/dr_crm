/**
 * Контроль подозрительной активности менеджеров.
 *
 * Каждое исходящее сообщение (кроме автоответов) проходит проверку по набору
 * правил. Если что-то сработало — в коллекцию riskEvents пишется событие,
 * которое админ видит в аналитике. Клиент писать в riskEvents не может
 * (правила Firestore) — данные собираются только на сервере.
 *
 * Стоимость: 1 чтение + 1 запись состояния на исходящее сообщение.
 */
import * as admin from "firebase-admin";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

export type RiskKind =
  | "cold" // первое сообщение номеру, который нам не писал
  | "mass" // один и тот же текст многим вручную (рассылка мимо модуля)
  | "burst" // слишком быстрый темп отправки
  | "night" // вне рабочих часов
  | "card" // реквизиты карты / Kaspi в тексте
  | "phone" // чужой номер телефона в тексте
  | "link" // ссылка новому контакту
  | "deleted" // менеджер удалил своё сообщение
  | "blast"; // серверная рассылка (кто запустил и на скольких)

/** Казахстан (Астана) — UTC+5. */
const TZ_OFFSET_H = 5;
const WORK_START = 8;
const WORK_END = 23;

const MASS_WINDOW_MS = 60 * 60_000;
const MASS_LIMIT = 5; // один текст ≥5 разным номерам за час
/**
 * Короткие ответы («Да, конечно», «Ждём вас») менеджеры пишут десяткам людей
 * в день — это обычная переписка, а не рассылка. Правило «одинаковый текст
 * многим» применяем только к длинным сообщениям (шаблон/приглашение).
 */
const MASS_MIN_LEN = 30;
const BURST_WINDOW_MS = 5 * 60_000;
const BURST_LIMIT = 12; // >12 разных чатов за 5 минут
const STATE_KEEP = 80; // сколько последних отправок держим в состоянии

const WEIGHT: Record<RiskKind, number> = {
  card: 3,
  mass: 3,
  blast: 2,
  cold: 2,
  phone: 2,
  burst: 2,
  deleted: 2,
  night: 1,
  link: 1,
};

// ── Текстовые проверки ────────────────────────────────────────────────────
const RE_CARD = /(?:\d[ .-]?){15}\d/; // 16 цифр — номер карты
const RE_IBAN = /KZ\d{2}[\dA-Z]{12,18}/i;
const RE_PAY = /(каспи|kaspi|halyk|халык|jusan|freedom|номер карты|на карту|перевод|iban|реквизит)/i;
const RE_PHONE = /(?:\+?7|8)[\s(-]?\d{3}[\s)-]?\d{3}[\s-]?\d{2}[\s-]?\d{2}/g;
const RE_LINK = /(https?:\/\/|www\.|t\.me\/|wa\.me\/|instagram\.com|telegram\.me)/i;

/** Локальный час (Астана) из UTC-времени. */
function localHour(d: Date): number {
  return (d.getUTCHours() + TZ_OFFSET_H + 24) % 24;
}

/** Ключ дня YYYY-MM-DD по местному времени (для группировки в UI). */
function localDayKey(d: Date): string {
  const shifted = new Date(d.getTime() + TZ_OFFSET_H * 3600_000);
  return shifted.toISOString().slice(0, 10);
}

/** Отпечаток текста: буквы в нижнем регистре без цифр, хвост 40 символов. */
function textKey(text: string): string {
  const norm = text
    .toLowerCase()
    .replace(/[\d]/g, "")
    .replace(/[^\p{L}\s]/gu, "")
    .replace(/\s+/g, " ")
    .trim();
  const tail = norm.length > 40 ? norm.slice(-40) : norm;
  let h = 5381;
  for (let i = 0; i < tail.length; i++) h = ((h << 5) + h + tail.charCodeAt(i)) | 0;
  return h.toString(36);
}

/** Только цифры (для сравнения телефонов с белым списком). */
const digits = (s: string) => s.replace(/\D/g, "");

/**
 * Признаки по самому тексту (без обращений к базе). Вынесено отдельно, чтобы
 * тем же кодом разбирать историю переписки (riskBackfill).
 */
export function textFlags(text: string, allow: string[], chatId: string, allowCards: string[] = []): RiskKind[] {
  const kinds: RiskKind[] = [];
  // Цифры внутри ссылок — не реквизиты. Id точки 2ГИС в шаблоне с адресом
  // (17 цифр подряд) выглядел для правил как номер карты и чужой телефон
  // сразу — каждая отправка адреса давала ложную «важную» тревогу, и журнал
  // тонул в шуме.
  const noUrls = text.replace(/(?:https?:\/\/|www\.)\S+/gi, " ");
  // Свои карты клиники (config/risk.allowedCards) нарушением не считаются:
  // менеджеры легально шлют реквизиты предоплаты много раз в день.
  let scrubbed = noUrls;
  for (const m of noUrls.match(new RegExp(RE_CARD.source, "g")) ?? []) {
    if (allowCards.includes(digits(m))) scrubbed = scrubbed.split(m).join("");
  }
  if (RE_CARD.test(scrubbed) || RE_IBAN.test(scrubbed) || (RE_PAY.test(scrubbed) && /\d{8,}/.test(scrubbed))) {
    kinds.push("card");
  }
  const found = noUrls.match(RE_PHONE) ?? [];
  if (found.length) {
    const outside = found
      .map(digits)
      .map((d) => (d.length === 11 && d.startsWith("8") ? `7${d.slice(1)}` : d))
      .filter((d) => d.length >= 10 && d !== digits(chatId) && !allow.includes(d));
    if (outside.length) kinds.push("phone");
  }
  return kinds;
}

/** Есть ли ссылка в тексте. */
export const hasLink = (text: string) => RE_LINK.test(text);

/** Отпечаток текста — для поиска «одинаковый текст многим». */
export const fingerprint = (text: string) => textKey(text);

/** Вне рабочих часов клиники (08:00–23:00 по Астане). */
export function isNight(d: Date): boolean {
  const h = localHour(d);
  return h < WORK_START || h >= WORK_END;
}

/** Свои номера из config/risk (с кэшем) — нужны и разбору истории. */
export const loadAllowedPhones = () => allowedPhones();

/** Локальный день YYYY-MM-DD (Астана) — для группировки. */
export const dayKey = (d: Date) => localDayKey(d);

/**
 * Признаки темпа по истории отправок менеджера: «одинаковый текст многим»
 * и «слишком быстро». Считается ДО отправки — по ним решается, ставить ли
 * сообщение в очередь.
 */
export function paceFlags(recent: Recent[], hash: string, text: string, nowMs: number): RiskKind[] {
  const kinds: RiskKind[] = [];
  const same = new Set(recent.filter((r) => r.h === hash && nowMs - r.t < MASS_WINDOW_MS).map((r) => r.c));
  if (text.trim().length >= MASS_MIN_LEN && same.size >= MASS_LIMIT) kinds.push("mass");
  const burst = new Set(recent.filter((r) => nowMs - r.t < BURST_WINDOW_MS).map((r) => r.c));
  if (burst.size > BURST_LIMIT) kinds.push("burst");
  return kinds;
}

// ── Кэши (живут в инстансе функции, экономят чтения) ──────────────────────
const nameCache = new Map<string, { name: string; at: number }>();
let allowCache: { phones: string[]; at: number } | null = null;
const CACHE_TTL = 10 * 60_000;

async function managerName(uid: string): Promise<string> {
  const hit = nameCache.get(uid);
  if (hit && Date.now() - hit.at < CACHE_TTL) return hit.name;
  try {
    const d = (await db().doc(`users/${uid}`).get()).data();
    const name = String(d?.name ?? "").trim();
    nameCache.set(uid, { name, at: Date.now() });
    return name;
  } catch {
    return "";
  }
}

/** Наши номера, которые можно писать клиентам (config/risk.allowedPhones). */
async function allowedPhones(): Promise<string[]> {
  if (allowCache && Date.now() - allowCache.at < CACHE_TTL) return allowCache.phones;
  try {
    const d = (await db().doc("config/risk").get()).data();
    const list = ((d?.allowedPhones ?? []) as unknown[])
      .filter((x): x is string => typeof x === "string")
      .map(digits)
      .filter((x) => x.length >= 10);
    allowCache = { phones: list, at: Date.now() };
    return list;
  } catch {
    return [];
  }
}

/** Свои карты клиники (config/risk.allowedCards) — не «слив реквизитов». */
let cardCache: { cards: string[]; at: number } | null = null;
export async function loadAllowedCards(): Promise<string[]> {
  if (cardCache && Date.now() - cardCache.at < CACHE_TTL) return cardCache.cards;
  try {
    const d = (await db().doc("config/risk").get()).data();
    const list = ((d?.allowedCards ?? []) as unknown[])
      .filter((x): x is string => typeof x === "string")
      .map(digits)
      .filter((x) => x.length >= 13);
    cardCache = { cards: list, at: Date.now() };
    return list;
  } catch {
    return [];
  }
}

// ── Состояние отправок менеджера ──────────────────────────────────────────
type Recent = { c: string; h: string; t: number };

/**
 * Дописывает отправку в riskState/{uid} и возвращает свежую историю
 * (последний час). Одно чтение + одна запись.
 */
export async function pushRecent(uid: string, chatId: string, hash: string): Promise<Recent[]> {
  const ref = db().doc(`riskState/${uid}`);
  const now = Date.now();
  let recent: Recent[] = [];
  try {
    const snap = await ref.get();
    recent = ((snap.data()?.recent ?? []) as Recent[]).filter(
      (r) => r && typeof r.t === "number" && now - r.t < MASS_WINDOW_MS,
    );
  } catch {
    recent = [];
  }
  recent.push({ c: chatId, h: hash, t: now });
  if (recent.length > STATE_KEEP) recent = recent.slice(-STATE_KEEP);
  await ref.set({ recent, updatedAt: ts() }, { merge: true });
  return recent;
}

// ── Публичное API ─────────────────────────────────────────────────────────

/**
 * Состояние диалога ДО записи исходящего: новый ли это контакт и писал ли
 * нам клиент когда-либо. Поле hasInbound проставляется один раз и дальше
 * читается бесплатно (вебхук ставит true на каждом входящем).
 */
export async function peekChat(chatId: string): Promise<{ cold: boolean }> {
  try {
    const ref = db().doc(`conversations/${chatId}`);
    const snap = await ref.get();
    if (!snap.exists) return { cold: true };
    const d = snap.data() ?? {};
    if (d.hasInbound === true) return { cold: false };
    if (d.hasInbound === false) return { cold: true };
    // Старый диалог без пометки — определяем один раз и запоминаем.
    const inbound = await db()
      .collection("messages")
      .where("conversationId", "==", chatId)
      .where("direction", "==", "inbound")
      .limit(1)
      .get();
    const has = !inbound.empty;
    await ref.set({ hasInbound: has }, { merge: true });
    return { cold: !has };
  } catch (e) {
    console.error("peekChat error", e);
    return { cold: false }; // при ошибке не выдумываем нарушение
  }
}

/** Запись события в riskEvents (общая точка для всех правил). */
export async function logRisk(p: {
  authorId: string;
  kinds: RiskKind[];
  chatId?: string;
  text?: string;
  messageId?: string;
  count?: number;
  docId?: string;
}): Promise<void> {
  if (!p.kinds.length) return;
  const score = p.kinds.reduce((s, k) => s + (WEIGHT[k] ?? 1), 0);
  const severity = score >= 3 ? "high" : score >= 2 ? "medium" : "low";
  const now = new Date();
  const doc = {
    authorId: p.authorId,
    authorName: await managerName(p.authorId),
    chatId: p.chatId ?? null,
    phone: p.chatId ?? null,
    text: (p.text ?? "").slice(0, 300),
    kinds: p.kinds,
    severity,
    score,
    count: p.count ?? null,
    messageId: p.messageId ?? null,
    day: localDayKey(now),
    createdAt: ts(),
  };
  const col = db().collection("riskEvents");
  if (p.docId) await col.doc(p.docId).set(doc, { merge: true });
  else await col.add(doc);
}

/**
 * Проверка исходящего сообщения менеджера. Вызывается ПОСЛЕ успешной
 * отправки; ошибки не пробрасываются (проверка не должна ломать отправку).
 */
export async function auditOutbound(p: {
  authorId: string;
  chatId: string;
  text: string;
  messageId: string;
  cold: boolean;
  /** Признаки темпа, посчитанные лимитером до отправки (mass/burst). */
  flags?: RiskKind[];
}): Promise<void> {
  try {
    const uid = p.authorId;
    if (!uid || uid === "auto") return;
    const text = p.text ?? "";
    const kinds: RiskKind[] = [...(p.flags ?? [])];

    // Если лимитер не отработал (медиа мимо очереди) — считаем темп здесь.
    if (p.flags == null) {
      const hash = textKey(text);
      const recent = await pushRecent(uid, p.chatId, hash);
      kinds.push(...paceFlags(recent, hash, text, Date.now()));
    }

    if (p.cold) kinds.push("cold");

    // Реквизиты карты/Kaspi и посторонний номер телефона в тексте.
    kinds.push(...textFlags(text, await allowedPhones(), p.chatId, await loadAllowedCards()));

    if (p.cold && hasLink(text)) kinds.push("link");
    if (isNight(new Date())) kinds.push("night");

    // Ночь/холодный контакт сами по себе — обычная работа. Событие пишем,
    // только если есть что-то весомое или совпало несколько признаков.
    const notable = kinds.some((k) => (WEIGHT[k] ?? 1) >= 2) || kinds.length >= 2;
    if (!notable) return;

    await logRisk({
      authorId: uid,
      kinds,
      chatId: p.chatId,
      text,
      messageId: p.messageId,
    });
  } catch (e) {
    console.error("auditOutbound error", e);
  }
}
