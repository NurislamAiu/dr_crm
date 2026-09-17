/**
 * Вечерняя сводка дня руководству в Telegram.
 *
 * Каждый вечер в 23:00 (Астана) бот сам присылает руководству картину дня:
 * сколько обращений, как быстро отвечали, кто из менеджеров сколько закрыл,
 * новые лиды и записи на завтра. Цифры — те же, что мы доставали руками
 * через диагностику, только оформленные и по расписанию.
 *
 * Получатели — в config/dailyReport:
 *   { enabled: true, chatIds: ["123456789", ...] }
 * chatId — личный Telegram-чат с ботом (человек должен один раз нажать
 * /start у бота, иначе Telegram не даст боту писать первым).
 */
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import { TELEGRAM_BOT_TOKEN } from "./telegram/secrets";
import { tgCall } from "./telegram/api";

const db = () => admin.firestore();

/** Астана — UTC+5 (единый пояс Казахстана с 2024 года). */
const TZ_OFFSET_MS = 5 * 3600_000;

/** Начало суток по Астане для момента t (мс UTC). */
export function reportDayStartMs(t: number): number {
  const local = new Date(t + TZ_OFFSET_MS);
  return Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate()) - TZ_OFFSET_MS;
}

const MONTHS = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];

function dateRu(msUtc: number): string {
  const d = new Date(msUtc + TZ_OFFSET_MS);
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;
}

function fmtMin(ms: number): string {
  const m = Math.round(ms / 60_000);
  if (m < 1) return "меньше минуты";
  if (m < 60) return `${m} мин`;
  return `${Math.floor(m / 60)} ч ${m % 60} мин`;
}

function median(xs: number[]): number | null {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)] ?? null;
}

/** Собрать текст сводки за сутки, начавшиеся в startMs (по Астане). */
export async function buildDailyReport(startMs: number): Promise<string> {
  const firestore = db();
  const endMs = startMs + 86_400_000;
  const startTs = admin.firestore.Timestamp.fromMillis(startMs);
  const endTs = admin.firestore.Timestamp.fromMillis(endMs);

  // ── Сообщения за день ────────────────────────────────────────────────────
  const msgs = await firestore
    .collection("messages")
    .where("createdAt", ">=", startTs)
    .where("createdAt", "<", endTs)
    .orderBy("createdAt", "asc")
    .limit(5000)
    .get();

  type ChatAgg = { firstInbound: number | null; replyAfter: number | null; humanReplyAfter: number | null; inbound: number };
  const chats = new Map<string, ChatAgg>();
  const managerMsgs = new Map<string, number>();
  const managerChats = new Map<string, Set<string>>();
  let inboundTotal = 0;
  let autoReplies = 0;
  let broadcastCount = 0;
  let followUps = 0;

  for (const doc of msgs.docs) {
    const x = doc.data();
    const chatId = String(x.conversationId ?? x.chatId ?? "");
    if (!chatId || x.isInternal === true || x.type === "call" || x.isDeleted === true) continue;
    const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    const agg = chats.get(chatId) ?? { firstInbound: null, replyAfter: null, humanReplyAfter: null, inbound: 0 };
    if (x.direction === "inbound") {
      inboundTotal++;
      agg.inbound++;
      agg.firstInbound ??= at;
    } else if (x.direction === "outbound") {
      // Догрев тоже уходит с authorId «auto» — без этой отметки он попадал
      // бы в «Автоответчик» ВТОРОЙ раз (уже учтён отдельной строкой ниже).
      const isFollowUp = x.queueReason === "follow" || x.followUp === true;
      if (isFollowUp) followUps++;
      if (x.isBroadcast === true) {
        broadcastCount++;
      } else {
        const author = String(x.authorId ?? "");
        if (author === "auto" && !isFollowUp) {
          autoReplies++;
        } else if (author && author !== "auto") {
          managerMsgs.set(author, (managerMsgs.get(author) ?? 0) + 1);
          (managerChats.get(author) ?? managerChats.set(author, new Set()).get(author)!).add(chatId);
        }
        // Первый ответ после первого входящего — скорость реакции.
        // Автоответ закрывает чат («отвечено»), но скорость меряем по живым
        // менеджерам: иначе медиана — это 8 секунд автоответчика.
        if (agg.firstInbound !== null && at >= agg.firstInbound) {
          agg.replyAfter ??= at;
          if (author && author !== "auto") agg.humanReplyAfter ??= at;
        }
      }
    }
    chats.set(chatId, agg);
  }

  const inboundChats = [...chats.entries()].filter(([, a]) => a.inbound > 0);
  const tgChats = inboundChats.filter(([id]) => id.startsWith("tg_")).length;
  const waChats = inboundChats.length - tgChats;
  const replied = inboundChats.filter(([, a]) => a.replyAfter !== null);
  const speeds = inboundChats
    .filter(([, a]) => a.humanReplyAfter !== null)
    .map(([, a]) => (a.humanReplyAfter ?? 0) - (a.firstInbound ?? 0))
    .filter((ms) => ms >= 0 && ms < 12 * 3600_000);
  const med = median(speeds);

  // ── Сколько чатов сейчас ждут ответа + темы дня ─────────────────────────
  let waitingNow = 0;
  let topicTraining = 0;
  let topicSupplements = 0;
  const refs = inboundChats.map(([id]) => firestore.collection("conversations").doc(id));
  for (let i = 0; i < refs.length; i += 100) {
    const part = await firestore.getAll(...refs.slice(i, i + 100));
    for (const d of part) {
      const c = d.data() ?? {};
      if (Number(c.unreadCount ?? 0) > 0 && c.blocked !== true) waitingNow++;
      if (c.topic === "training") topicTraining++;
      if (c.topic === "supplements") topicSupplements++;
    }
  }

  // ── Имена менеджеров ─────────────────────────────────────────────────────
  const users = await firestore.collection("users").limit(50).get();
  const names = new Map(users.docs.map((d) => [d.id, String(d.data().name ?? "").trim() || d.id.slice(0, 6)]));

  // ── Новые лиды за день и записи на завтра ───────────────────────────────
  const leadsToday = await firestore.collection("leads").where("createdAt", ">=", startTs).where("createdAt", "<", endTs).get();
  const newLeads = leadsToday.docs.filter((d) => d.data().archived !== true).length;

  const t0 = admin.firestore.Timestamp.fromMillis(endMs);
  const t1 = admin.firestore.Timestamp.fromMillis(endMs + 86_400_000);
  const [leadsTomorrow, massTomorrow] = await Promise.all([
    firestore.collection("leads").where("appointmentDate", ">=", t0).where("appointmentDate", "<", t1).get(),
    firestore.collection("massages").where("appointmentDate", ">=", t0).where("appointmentDate", "<", t1).get(),
  ]);
  const tomorrow: { time: string }[] = [];
  const seenPhones = new Set<string>();
  for (const d of [...leadsTomorrow.docs, ...massTomorrow.docs]) {
    const x = d.data();
    if (x.archived === true) continue;
    const phone = String(x.phone ?? "").replace(/\D/g, "");
    const key = phone || d.id;
    if (seenPhones.has(key)) continue;
    seenPhones.add(key);
    tomorrow.push({ time: String(x.appointmentTime ?? "").trim() });
  }
  const times = tomorrow.map((a) => a.time).filter((t) => /^\d{1,2}:\d{2}$/.test(t)).sort();

  // ── Текст ────────────────────────────────────────────────────────────────
  const lines: string[] = [];
  lines.push(`📊 Сводка за ${dateRu(startMs)}`);
  lines.push("");
  lines.push("💬 Обращения");
  lines.push(`• Писали: ${inboundChats.length} чатов (Telegram ${tgChats} · WhatsApp ${waChats}), сообщений: ${inboundTotal}`);
  lines.push(`• Отвечено: ${replied.length} из ${inboundChats.length}` + (waitingNow > 0 ? ` · сейчас ждут ответа: ${waitingNow}` : " · без ответа никого"));
  if (med !== null) lines.push(`• Скорость первого ответа менеджера: ${fmtMin(med)} (медиана)`);
  lines.push("");
  lines.push(`🧲 Новые лиды: ${newLeads}`);
  if (topicTraining > 0 || topicSupplements > 0) {
    const parts: string[] = [];
    if (topicTraining > 0) parts.push(`🎓 обучение: ${topicTraining}`);
    if (topicSupplements > 0) parts.push(`🌿 БАДы: ${topicSupplements}`);
    lines.push(parts.join(" · "));
  }
  lines.push("");
  lines.push("👥 Менеджеры");
  const perManager = [...managerMsgs.entries()].sort((a, b) => b[1] - a[1]);
  if (perManager.length === 0) lines.push("• сегодня сообщений не отправляли");
  for (const [uid, count] of perManager) {
    lines.push(`• ${names.get(uid) ?? uid.slice(0, 6)} — ${count} сообщений · ${managerChats.get(uid)?.size ?? 0} чатов`);
  }
  if (autoReplies > 0) lines.push(`• Автоответчик — ${autoReplies}`);
  if (followUps > 0) lines.push(`• Догрев (напомнили о записи) — ${followUps}`);
  if (broadcastCount > 0) lines.push(`• Рассылка — ${broadcastCount}`);
  lines.push("");
  lines.push(
    tomorrow.length === 0
      ? "📅 На завтра записей нет"
      : `📅 Завтра записей: ${tomorrow.length}` +
          (times.length > 0 ? ` (с ${times[0]} до ${times[times.length - 1]})` : ""),
  );
  return lines.join("\n");
}

/** Получатели сводки из config/dailyReport. */
export async function reportRecipients(): Promise<{ enabled: boolean; chatIds: string[] }> {
  const d = (await db().doc("config/dailyReport").get()).data() ?? {};
  const chatIds = ((d.chatIds ?? []) as unknown[])
    .map((v) => String(v).replace(/^tg_/, "").trim())
    .filter((v) => /^\d+$/.test(v));
  return { enabled: d.enabled !== false, chatIds };
}

/** Отправить текст в личные Telegram-чаты получателей. */
export async function sendReport(token: string, chatIds: string[], text: string): Promise<{ sent: string[]; failed: string[] }> {
  const sent: string[] = [];
  const failed: string[] = [];
  for (const id of chatIds) {
    try {
      await tgCall(token, "sendMessage", { chat_id: Number(id), text });
      sent.push(id);
    } catch (e) {
      console.error("dailyReport send fail", id, String(e instanceof Error ? e.message : e));
      failed.push(id);
    }
  }
  return { sent, failed };
}

/** Каждый вечер в 23:00 по Астане. */
export const dailyReport = onSchedule(
  { schedule: "0 23 * * *", timeZone: "Asia/Almaty", secrets: [TELEGRAM_BOT_TOKEN], timeoutSeconds: 300 },
  async () => {
    const { enabled, chatIds } = await reportRecipients();
    if (!enabled || chatIds.length === 0) {
      console.log("dailyReport: выключена или нет получателей (config/dailyReport.chatIds)");
      return;
    }
    const text = await buildDailyReport(reportDayStartMs(Date.now()));
    await sendReport(TELEGRAM_BOT_TOKEN.value(), chatIds, text);
  },
);
