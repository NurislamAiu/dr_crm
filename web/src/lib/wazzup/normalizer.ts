import {
  WebhookPayloadSchema,
  MESSAGE_TYPES,
  type WebhookPayload,
  type WebhookMessage,
  type WebhookStatus,
  type WebhookChannelUpdate,
} from "./schemas";

/**
 * Нормализатор webhook Wazzup (ТЗ §6, §8, §9, §17).
 *
 * Ключевые инварианты:
 *  - messages и statuses обрабатываются НЕЗАВИСИМО (без if/else, оба массива);
 *  - неизвестный тип не роняет обработку → normalizedType="unknown", raw сохраняем;
 *  - направление по isEcho (false=incoming, true=outgoing);
 *  - chatId нормализуется (для whatsapp — только цифры).
 */

export type Direction = "inbound" | "outbound";

export interface NormalizedMessage {
  externalMessageId: string;
  channelId: string;
  chatType: string;
  chatId: string;
  chatIdNormalized: string;
  direction: Direction;
  /** Тип из ENUM MESSAGE_TYPES либо "unknown" (fallback). */
  type: (typeof MESSAGE_TYPES)[number];
  /** Исходный тип от провайдера (для диагностики нераспознанных). */
  rawType: string;
  text: string | null;
  contentUri: string | null;
  hasContent: boolean;
  authorName: string | null;
  authorId: string | null;
  contactName: string | null;
  contactPhone: string | null;
  isEdited: boolean;
  isDeleted: boolean;
  /** Текст до редактирования/удаления (oldInfo.oldText). */
  oldText: string | null;
  providerDateTime: string | null;
  /** Понятная менеджеру метка для спец-типов. */
  displayHint: string | null;
  raw: WebhookMessage;
}

export interface NormalizedStatus {
  externalMessageId: string;
  status: string;
  /** §1 п.6: в statuses поле называется timestamp, не dateTime. */
  timestamp: string | null;
  errorCode: string | null;
  errorDescription: string | null;
  raw: WebhookStatus;
}

export interface NormalizedChannelUpdate {
  channelId: string;
  state: string;
  qr: string | null;
  qridle: string | null;
  raw: WebhookChannelUpdate;
}

export interface NormalizedWebhook {
  isTest: boolean;
  messages: NormalizedMessage[];
  statuses: NormalizedStatus[];
  channelUpdates: NormalizedChannelUpdate[];
}

/** Нормализация chatId: для whatsapp — только цифры (ТЗ §8, §11 п.1). */
export function normalizeChatId(chatType: string, chatId: string): string {
  if (chatType === "whatsapp" || chatType === "whatsgroup" || chatType === "viber") {
    return chatId.replace(/\D/g, "");
  }
  return chatId.trim();
}

function toKnownType(rawType: string): (typeof MESSAGE_TYPES)[number] {
  return (MESSAGE_TYPES as readonly string[]).includes(rawType)
    ? (rawType as (typeof MESSAGE_TYPES)[number])
    : "unknown";
}

/** Понятная менеджеру подсказка для спец-типов (ТЗ §9). */
function displayHintFor(type: string, isDeleted: boolean): string | null {
  if (isDeleted) return "Сообщение удалено";
  switch (type) {
    case "missing_call":
      return "Пропущенный звонок WhatsApp";
    case "unsupported":
    case "unknown":
      return "Получено сообщение неподдерживаемого типа";
    default:
      return null;
  }
}

function normalizeMessage(m: WebhookMessage): NormalizedMessage {
  const knownType = toKnownType(m.type);
  const isDeleted = m.isDeleted === true;
  const contentUri = m.contentUri ?? null;
  const text = m.text ?? null;
  return {
    externalMessageId: m.messageId,
    channelId: m.channelId,
    chatType: m.chatType,
    chatId: m.chatId,
    chatIdNormalized: normalizeChatId(m.chatType, m.chatId),
    direction: m.isEcho ? "outbound" : "inbound",
    type: knownType,
    rawType: m.type,
    text,
    contentUri,
    hasContent: Boolean(contentUri),
    authorName: m.authorName ?? null,
    authorId: m.authorId ?? null,
    contactName: m.contact?.name ?? null,
    contactPhone: m.contact?.phone ?? null,
    isEdited: m.isEdited === true,
    isDeleted,
    oldText: m.oldInfo?.oldText ?? null,
    providerDateTime: m.dateTime ?? null,
    displayHint: displayHintFor(knownType, isDeleted),
    raw: m,
  };
}

function normalizeStatus(s: WebhookStatus): NormalizedStatus {
  return {
    externalMessageId: s.messageId,
    status: s.status,
    timestamp: s.timestamp ?? null,
    errorCode: s.error?.error ?? null,
    errorDescription: s.error?.description ?? null,
    raw: s,
  };
}

function normalizeChannelUpdate(c: WebhookChannelUpdate): NormalizedChannelUpdate {
  return {
    channelId: c.channelId,
    state: c.state,
    qr: c.qr ?? null,
    qridle: c.qridle ?? null,
    raw: c,
  };
}

/**
 * Главная функция. Принимает уже распарсенный JSON, валидирует и нормализует.
 * Бросает ZodError только на структурно-невалидный payload; неизвестные ТИПЫ
 * сообщений не считаются ошибкой.
 */
export function normalizeWebhook(input: unknown): NormalizedWebhook {
  const payload: WebhookPayload = WebhookPayloadSchema.parse(input);
  return {
    isTest: payload.test === true,
    messages: (payload.messages ?? []).map(normalizeMessage),
    statuses: (payload.statuses ?? []).map(normalizeStatus),
    channelUpdates: (payload.channelsUpdates ?? []).map(normalizeChannelUpdate),
  };
}
