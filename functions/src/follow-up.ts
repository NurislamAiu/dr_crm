/**
 * Догрев «недожатых» обращений — ОДНО вежливое напоминание.
 *
 * Кому: клиент сегодня интересовался приёмом, менеджер ответил, клиент
 * замолчал на несколько часов — и записи так и нет. Таким через 4+ часа
 * тишины уходит одно сервисное сообщение («подсказать по записи?»).
 *
 * Жёсткие правила (согласованы с владельцем 2026-08-17):
 *  • РОВНО ОДИН РАЗ за всю жизнь чата (followUpSentAt) — никаких «каждый вечер»;
 *  • НЕ отправляется: лидам (уже записан), VIP-клиентам, записанным на массаж,
 *    заблокированным, темам обучение/БАДы (у них свои сценарии);
 *  • только днём (10:00–20:00 Астаны);
 *  • WhatsApp — только пока открыто 24-часовое окно (бесплатно, без шаблона);
 *  • отменяется, если менеджер успел написать сам (механизм автоответа);
 *  • не больше 15 за один заход, с разбросом по времени — не похоже на рассылку.
 */
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import { TELEGRAM_BOT_TOKEN } from "./telegram/secrets";
import { tgSendTextApi } from "./telegram/api";
import { enqueue } from "./limits";
import { isOwnTabTopic } from "./topics";
import { uniquifyText } from "./variate";
import { randomUUID } from "crypto";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

/** Астана — UTC+5. */
const TZ_OFFSET_MS = 5 * 3600_000;

const DEFAULT_VARIANTS = [
  "Подсказать по записи? Напишите удобный день — подберём время 😊",
  "Если остались вопросы по приёму — с радостью ответим. Подобрать удобное время?",
  "Ещё думаете? Скажите удобный день — посмотрим свободное время на приём.",
];

type Cfg = {
  enabled: boolean;
  delayHours: number; // сколько часов тишины ждать
  startHour: number; // окно отправки по Астане
  endHour: number;
  variants: string[];
};

async function cfg(): Promise<Cfg> {
  const d = (await db().doc("config/followUp").get()).data() ?? {};
  const list = ((d.variants ?? []) as unknown[]).filter((s): s is string => typeof s === "string" && s.trim().length > 0);
  const num = (v: unknown, def: number, min: number, max: number) => {
    const n = Number(v);
    return Number.isFinite(n) ? Math.min(Math.max(n, min), max) : def;
  };
  return {
    enabled: d.enabled !== false,
    delayHours: num(d.delayHours, 4, 1, 12),
    startHour: num(d.startHour, 10, 0, 23),
    endHour: num(d.endHour, 20, 1, 24),
    variants: list.length > 0 ? list : DEFAULT_VARIANTS,
  };
}

/** Последние 10 цифр — телефоны в базе записаны в разных форматах. */
function tail10(phone: unknown): string {
  const d = String(phone ?? "").replace(/\D/g, "");
  return d.slice(-10);
}

/**
 * Разговор ЗАВЕРШЁН, а не брошен: менеджер попрощался («ждём вас»,
 * «хорошо», «спасибо», «до встречи»). Часто это значит, что клиент
 * договорился, но менеджер забыл сохранить лида, — напоминание «ещё
 * думаете?» такому человеку выглядит глупо и подрывает доверие.
 *
 * Фразы-завершения ловятся в любом месте сообщения; короткие слова
 * («хорошо», «ок», «спасибо») — только если само сообщение короткое.
 * Список пополняется без деплоя: config/followUp.closingPhrases.
 */
const CLOSING_PHRASES = [
  "ждем вас", "будем ждать", "будем вас ждать", "ждем",
  "до встречи", "до свидания", "всего доброго",
  "хорошего дня", "хорошего вечера", "доброго пути",
  "договорились", "вы записаны", "записали вас", "записал вас", "записала вас",
  "приходите", "подходите", "приезжайте",
  "рады будем", "обращайтесь", "на связи",
];

const CLOSING_SHORT = [
  "хорошо", "ок", "окей", "спасибо", "спасиба", "рахмет",
  "пожалуйста", "не за что", "отлично", "супер", "принято", "добро",
];

export function isClosingMessage(raw: string, extra: string[] = []): boolean {
  const t = raw
    .toLowerCase()
    .replace(/ё/g, "е")
    .replace(/[^a-zа-я0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
  if (t.length === 0) return false;
  if ([...CLOSING_PHRASES, ...extra].some((p) => t.includes(p))) return true;
  if (t.length <= 40 && CLOSING_SHORT.some((w) => t.includes(w))) return true;
  return false;
}

/** Телефоны, которым догрев НЕ отправляется: лиды, VIP, массаж. */
async function excludedPhones(): Promise<Set<string>> {
  const firestore = db();
  const out = new Set<string>();
  const [leads, mass, vip] = await Promise.all([
    firestore.collection("leads").select("phone", "archived").limit(3000).get(),
    firestore.collection("massages").select("phone", "archived").limit(3000).get(),
    firestore.collection("clients").select("phone", "archived").limit(3000).get(),
  ]);
  // Архивный лид/массаж/VIP — снова обычный клиент, догрев ему уместен.
  for (const d of [...leads.docs, ...mass.docs, ...vip.docs]) {
    const x = d.data();
    if (x.archived === true) continue;
    const p = tail10(x.phone);
    if (p.length === 10) out.add(p);
  }
  return out;
}

export type FollowCandidate = {
  id: string;
  name: string;
  phone: string | null;
  silentHours: number;
  transport: "telegram" | "whatsapp";
};

/** Чаты, подходящие под догрев прямо сейчас. */
export async function followCandidates(now: number, delayHours: number): Promise<FollowCandidate[]> {
  const firestore = db();
  // Клиент писал в последние 20 часов (окно WhatsApp ещё открыто с запасом).
  const snap = await firestore
    .collection("conversations")
    .where("lastInboundAt", ">=", admin.firestore.Timestamp.fromMillis(now - 20 * 3600_000))
    .limit(500)
    .get();

  const closingExtra = (((await firestore.doc("config/followUp").get()).data() ?? {}).closingPhrases ?? []) as unknown[];
  const extra = closingExtra.map((s) => String(s).toLowerCase().trim()).filter((s) => s.length >= 2);

  const excluded = await excludedPhones();
  const out: FollowCandidate[] = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    if (d.blocked === true) continue;
    if (d.followUpSentAt) continue; // уже напоминали — никогда повторно
    if (d.lastOutbound !== true) continue; // последнее слово за клиентом — это менеджеру отвечать
    if (isOwnTabTopic(d.topic)) continue; // обучение/БАДы — свои сценарии
    // Менеджер попрощался («ждём вас», «хорошо», «спасибо») — разговор
    // завершён, скорее всего клиент договорился. Не лезем.
    if (isClosingMessage(String(d.lastMessagePreview ?? ""), extra)) continue;
    const lastIn = (d.lastInboundAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    const lastAny = (d.lastMessageAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    const silent = now - lastIn;
    if (silent < delayHours * 3600_000) continue; // ещё рано
    if (now - lastAny < 3 * 3600_000) continue; // недавно была активность — не лезем
    const phone = typeof d.phone === "string" && d.phone ? String(d.phone) : null;
    // Уже лид / VIP / массаж — не трогаем (главное правило владельца).
    if (phone && excluded.has(tail10(phone))) continue;
    out.push({
      id: doc.id,
      name: String(d.name ?? doc.id),
      phone,
      silentHours: Math.round(silent / 3600_000),
      transport: doc.id.startsWith("tg_") ? "telegram" : "whatsapp",
    });
  }
  return out;
}

/** Отправить догрев одному чату. Отметка ставится ДО отправки (транзакция). */
async function sendFollowUp(c: FollowCandidate, text: string, tgToken: string): Promise<boolean> {
  const firestore = db();
  const ref = firestore.collection("conversations").doc(c.id);
  const claimed = await firestore.runTransaction(async (tx) => {
    const d = (await tx.get(ref)).data() ?? {};
    if (d.followUpSentAt || d.blocked === true) return false;
    tx.set(ref, { followUpSentAt: ts() }, { merge: true });
    return true;
  });
  if (!claimed) return false;

  if (c.transport === "whatsapp") {
    // Через общую очередь: та же «человечная» пауза и отмена, если менеджер
    // успел ответить сам (autoReply-механизм). Темп задаёт планировщик:
    // одно сообщение за запуск, запуски раз в 5 минут.
    await enqueue({
      kind: "text",
      chatId: c.id,
      text: uniquifyText(text, c.id),
      authorId: "auto",
      crmMessageId: randomUUID(),
      reason: "follow",
      autoReply: true,
      nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + 5000 + Math.floor(Math.random() * 30_000)),
    });
    return true;
  }

  // Telegram: шлём напрямую и записываем сообщение в переписку.
  try {
    const tgChatId = c.id.replace(/^tg_/, "");
    const sent = await tgSendTextApi(tgToken, { chatId: Number(tgChatId), text });
    await firestore.collection("messages").doc(`tg_${tgChatId}_${sent.message_id}`).set({
      conversationId: c.id,
      chatId: c.id,
      tgMessageId: sent.message_id,
      direction: "outbound",
      type: "text",
      text,
      status: "sent",
      authorId: "auto",
      followUp: true,
      createdAt: ts(),
    });
    // Чат в списке НЕ поднимаем: автосообщения не двигают порядок,
    // наверх чат выносит только новое сообщение клиента.
    await ref.set({ updatedAt: ts() }, { merge: true });
    return true;
  } catch (e) {
    // Клиент заблокировал бота и т.п. — отметка остаётся, повторов не будет.
    console.error("followUp tg fail", c.id, String(e instanceof Error ? e.message : e));
    return false;
  }
}

/**
 * Один заход догрева: ОДНО сообщение за запуск. Запуск — раз в 5 минут,
 * поэтому между любыми двумя догревами минимум 5 минут (требование владельца
 * 2026-08-18 после первой версии, где пачка по 12 уходила за минуту —
 * WhatsApp такое читает как рассылку).
 */
export async function runFollowUps(tgToken: string, opts?: { force?: boolean; limit?: number }): Promise<{
  candidates: number;
  sent: number;
  skippedByHours: boolean;
}> {
  const c = await cfg();
  if (!c.enabled) return { candidates: 0, sent: 0, skippedByHours: false };
  const now = Date.now();
  const hour = new Date(now + TZ_OFFSET_MS).getUTCHours();
  if (!opts?.force && (hour < c.startHour || hour >= c.endHour)) {
    return { candidates: 0, sent: 0, skippedByHours: true };
  }
  const list = await followCandidates(now, c.delayHours);
  const cap = Math.min(opts?.limit ?? 1, 3);
  let sent = 0;
  for (const cand of list) {
    if (sent >= cap) break;
    const text = c.variants[Math.floor(Math.random() * c.variants.length)] ?? DEFAULT_VARIANTS[0]!;
    if (await sendFollowUp(cand, text, tgToken)) sent++;
  }
  return { candidates: list.length, sent, skippedByHours: false };
}

/** Каждые 5 минут по одному сообщению; окно 10:00–20:00 Астаны — внутри. */
export const followUp = onSchedule(
  { schedule: "*/5 * * * *", timeZone: "Asia/Almaty", secrets: [TELEGRAM_BOT_TOKEN], timeoutSeconds: 300 },
  async () => {
    const r = await runFollowUps(TELEGRAM_BOT_TOKEN.value());
    if (r.sent > 0) console.log("followUp", JSON.stringify(r));
  },
);
