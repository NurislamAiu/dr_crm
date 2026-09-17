/**
 * Лимит темпа отправки и очередь сообщений.
 *
 * Смысл: WhatsApp банит номер за объём и однотипность. Поэтому весь исходящий
 * поток проходит через один счётчик канала: пока в пределах лимита — уходит
 * сразу, сверх лимита (или когда один текст пошёл многим) — сообщение падает в
 * очередь outbox и досылается фоном ровным темпом.
 *
 * Менеджер видит сообщение в чате сразу со статусом «queued» (часики).
 */
import * as admin from "firebase-admin";
import { dayKey, fingerprint, paceFlags, pushRecent, type RiskKind } from "./risk";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

export type Limits = {
  enabled: boolean;
  hourLimit: number; // сколько сообщений в час можно с номера
  dayLimit: number; // и за сутки
  queueMass: boolean; // одинаковый текст 5+ адресатам — тоже через очередь
  drainGapSec: number; // пауза между досылками из очереди
};

const DEF: Limits = { enabled: true, hourLimit: 120, dayLimit: 900, queueMass: true, drainGapSec: 11 };

let cache: { v: Limits; at: number } | null = null;

/** Настройки из config/risk (кэш на минуту). */
export async function limits(): Promise<Limits> {
  if (cache && Date.now() - cache.at < 60_000) return cache.v;
  let v = { ...DEF };
  try {
    const d = (await db().doc("config/risk").get()).data() ?? {};
    v = {
      enabled: d.limitEnabled !== false,
      hourLimit: typeof d.hourLimit === "number" ? Math.max(10, d.hourLimit) : DEF.hourLimit,
      dayLimit: typeof d.dayLimit === "number" ? Math.max(50, d.dayLimit) : DEF.dayLimit,
      queueMass: d.queueMass !== false,
      drainGapSec: typeof d.drainGapSec === "number" ? Math.max(3, d.drainGapSec) : DEF.drainGapSec,
    };
  } catch {
    /* при ошибке — значения по умолчанию */
  }
  cache = { v, at: Date.now() };
  return v;
}

const CHANNEL_DOC = "riskState/_channel";

/**
 * Резервирует слот отправки в счётчике канала (транзакция — гонок между
 * инстансами нет). Если лимит исчерпан, слот не занимается.
 */
export async function reserveSlot(): Promise<{ allow: boolean; reason?: "hour" | "day"; hour: number; day: number }> {
  const lim = await limits();
  const ref = db().doc(CHANNEL_DOC);
  return db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const d = snap.data() ?? {};
    const now = Date.now();
    const sends = ((d.sends ?? []) as unknown[])
      .filter((t): t is number => typeof t === "number")
      .filter((t) => now - t < 3600_000);
    const today = dayKey(new Date(now));
    const dayCount = d.day === today ? Number(d.dayCount ?? 0) : 0;
    const hour = sends.length;

    if (lim.enabled) {
      if (hour >= lim.hourLimit) return { allow: false, reason: "hour" as const, hour, day: dayCount };
      if (dayCount >= lim.dayLimit) return { allow: false, reason: "day" as const, hour, day: dayCount };
    }
    sends.push(now);
    tx.set(ref, { sends: sends.slice(-1000), day: today, dayCount: dayCount + 1, updatedAt: ts() }, { merge: true });
    return { allow: true, hour: hour + 1, day: dayCount + 1 };
  });
}

export type Gate = {
  send: boolean;
  reason?: "hour" | "day" | "mass";
  flags: RiskKind[];
  hour: number;
  day: number;
};

/**
 * Пропустить сообщение сейчас или поставить в очередь. Заодно возвращает
 * признаки темпа для журнала (чтобы не читать состояние второй раз).
 */
export async function gateSend(p: {
  authorId: string;
  chatId: string;
  text: string;
  broadcast?: boolean;
  /** Медиа: правило «одинаковый текст многим» к нему неприменимо. */
  skipMass?: boolean;
}): Promise<Gate> {
  const lim = await limits();
  let flags: RiskKind[] = [];
  try {
    const hash = fingerprint(p.text);
    const recent = await pushRecent(p.authorId || "unknown", p.chatId, hash);
    flags = paceFlags(recent, hash, p.text, Date.now());
  } catch {
    flags = [];
  }

  // «Один текст многим» — самая частая причина бана: досылаем ровным темпом.
  if (lim.enabled && lim.queueMass && !p.broadcast && !p.skipMass && flags.includes("mass")) {
    return { send: false, reason: "mass", flags, hour: 0, day: 0 };
  }

  const slot = await reserveSlot();
  if (!slot.allow) return { send: false, reason: slot.reason, flags, hour: slot.hour, day: slot.day };
  return { send: true, flags, hour: slot.hour, day: slot.day };
}

export type OutboxItem = {
  /** template — одобренный Meta шаблон WABA (рассылка/напоминание). */
  kind: "text" | "media" | "template";
  chatId: string;
  text?: string;
  name?: string;
  authorId: string;
  refMessageId?: string;
  replyToText?: string;
  mediaPath?: string;
  mediaUrl?: string;
  mediaType?: string;
  crmMessageId: string;
  reason?: string;
  /** WABA: ждём, пока клиент ответит — до этого свободный текст не уйдёт. */
  waitWindow?: boolean;
  /** «Человечная» задержка: до этого момента processOutbox не отправляет. */
  nextAttemptAt?: admin.firestore.Timestamp;
  /** Автоответ на первое обращение: отменяется, если менеджер ответил сам. */
  autoReply?: boolean;
  /** Шаблон WABA: guid из кабинета Wazzup и значения переменных {{1}}, {{2}}… */
  templateId?: string;
  templateValues?: string[];
  /** Часть рассылки — помечаем в переписке и в модуле контроля. */
  broadcast?: boolean;
};

/**
 * Кладёт сообщение в очередь и сразу показывает его в чате со статусом
 * «queued» — менеджер видит, что оно принято и уйдёт чуть позже.
 */
export async function enqueue(item: OutboxItem): Promise<string> {
  const firestore = db();
  const preview = item.kind === "media" ? `[${item.mediaType ?? "файл"}]` : (item.text ?? "");
  const name = (item.name ?? "").trim() || `+${item.chatId}`;

  // ВАЖНО: Firestore падает на undefined в значениях — пустые поля выкидываем.
  const row: Record<string, unknown> = { status: "pending", attempts: 0, createdAt: ts() };
  for (const [k, v] of Object.entries(item)) {
    if (v !== undefined) row[k] = v;
  }
  await firestore.collection("outbox").doc(item.crmMessageId).set(row);

  await firestore.collection("messages").doc(item.crmMessageId).set(
    {
      conversationId: item.chatId,
      chatId: item.chatId,
      direction: "outbound",
      type: item.kind === "media" ? (item.mediaType ?? "document") : "text",
      text: item.kind === "media" ? null : (item.text ?? ""),
      mediaUrl: item.mediaUrl ?? null,
      status: "queued",
      authorId: item.authorId,
      crmMessageId: item.crmMessageId,
      queued: true,
      queueReason: item.reason ?? null,
      ...(item.kind === "template" ? { isTemplate: true } : {}),
      ...(item.broadcast ? { isBroadcast: true } : {}),
      ...(item.refMessageId ? { replyToId: item.refMessageId, replyToText: (item.replyToText ?? "").slice(0, 200) } : {}),
      createdAt: ts(),
    },
    { merge: true },
  );

  // Автоответчик и догрев (authorId 'auto') чат в списке НЕ поднимают:
  // порядок двигает только новое сообщение клиента (и живой ответ менеджера).
  // Иначе пачка автосообщений выталкивала неотвеченные переписки вниз.
  const bump = item.authorId === "auto"
      ? {}
      : {
          lastMessageAt: ts(), lastMessagePreview: preview,
          lastOutbound: true, lastAuthorId: item.authorId, lastAuthorName: null,
        };
  await firestore.collection("conversations").doc(item.chatId).set(
    {
      contactId: item.chatId, phone: item.chatId, name, chatType: "whatsapp", status: "open",
      ...bump,
      updatedAt: ts(),
    },
    { merge: true },
  );
  return item.crmMessageId;
}

/** Сколько сообщений ждёт отправки (для карточки в аналитике). */
export async function queueSize(): Promise<number> {
  const snap = await db().collection("outbox").where("status", "==", "pending").count().get();
  return snap.data().count ?? 0;
}
