import { z } from "zod";

/**
 * Zod-схемы Wazzup User API v3.
 * Сверено по официальной документации (wazzup24.com/help/api-en) 2026-07-19.
 * Расхождения с ТЗ описаны в /architecture.md §1.
 */

// --- Транспорты каналов (GET /v3/channels) ---
export const WazzupTransport = z.enum([
  "whatsapp",
  "wapi",
  "instagram",
  "tgapi",
  "telegram",
  "vk",
  "avito",
]);
export type WazzupTransport = z.infer<typeof WazzupTransport>;

/**
 * Состояния канала. В ТЗ фигурирует `qridle`, но по документации состояние
 * называется `qr` (§1, п.1). `qridle` приходит отдельным полем в webhook
 * channelsUpdates. `unknown` — наш локальный fallback (не падать).
 */
export const KNOWN_CHANNEL_STATES = [
  "active",
  "init",
  "disabled",
  "qr",
  "phoneUnavailable",
  "openElsewhere",
  "notEnoughMoney",
  "foreignphone",
  "unauthorized",
  "waitForPassword",
  "onModeration", // WABA
  "rejected", // WABA
] as const;

// Принимаем любую строку (провайдер может добавить новое состояние),
// но типobias фиксируем известные + fallback "unknown".
export const ChannelStateSchema = z.string();
export type ChannelState = (typeof KNOWN_CHANNEL_STATES)[number] | "unknown" | (string & {});

export const ChannelSchema = z.object({
  channelId: z.string(),
  transport: z.string(), // не enum: чужие транспорты не должны валить парсинг
  plainId: z.string(),
  state: ChannelStateSchema,
});
export type Channel = z.infer<typeof ChannelSchema>;

export const ChannelsResponseSchema = z.array(ChannelSchema);

// --- Отправка сообщения (POST /v3/message) ---
export const ChatTypeSchema = z.enum([
  "whatsapp",
  "whatsgroup",
  "viber",
  "instagram",
  "telegram",
]);
export type ChatType = z.infer<typeof ChatTypeSchema>;

export const SendMessageResponseSchema = z.object({
  messageId: z.string(),
  chatId: z.string(),
});
export type SendMessageResponse = z.infer<typeof SendMessageResponseSchema>;

// --- Настройки webhook (GET/PATCH /v3/webhooks) ---
export const WebhookSubscriptionsSchema = z.object({
  messagesAndStatuses: z.boolean().optional(),
  contactsAndDealsCreation: z.boolean().optional(),
  channelsUpdates: z.boolean().optional(),
  templateStatus: z.boolean().optional(),
});
export type WebhookSubscriptions = z.infer<typeof WebhookSubscriptionsSchema>;

export const WebhookSettingsSchema = z.object({
  webhooksUri: z.string(),
  subscriptions: WebhookSubscriptionsSchema,
});
export type WebhookSettings = z.infer<typeof WebhookSettingsSchema>;

// --- Пользователи (POST/GET /v3/users) ---
export const WazzupUserSchema = z.object({
  id: z.string().max(200),
  name: z.string().max(200),
  phone: z.string().optional(),
});
export type WazzupUser = z.infer<typeof WazzupUserSchema>;
export const WazzupUsersResponseSchema = z.array(
  z.object({ id: z.string(), name: z.string() }),
);

// --- Контакты (POST/GET /v3/contacts) ---
export const ContactDataSchema = z.object({
  chatType: ChatTypeSchema,
  chatId: z.string(),
  username: z.string().optional(),
  phone: z.string().optional(),
});
export const WazzupContactSchema = z.object({
  id: z.string().max(100),
  responsibleUserId: z.string().max(100),
  name: z.string().max(200),
  contactData: z.array(ContactDataSchema).min(1),
  uri: z.string().max(200).optional(),
});
export type WazzupContact = z.infer<typeof WazzupContactSchema>;

// --- Формат ошибки Wazzup (§1, п.8: есть status и requestId) ---
export const WazzupErrorBodySchema = z.object({
  status: z.number().optional(),
  requestId: z.string().optional(),
  error: z.string(),
  description: z.string().optional(),
  data: z.unknown().optional(),
});
export type WazzupErrorBody = z.infer<typeof WazzupErrorBodySchema>;

// --- Webhook payload: входящие сообщения (messages) ---
export const MESSAGE_TYPES = [
  "text",
  "image",
  "audio",
  "video",
  "document",
  "vcard",
  "geo",
  "wapi_template",
  "unsupported",
  "missing_call",
  "unknown",
] as const;

export const WebhookMessageSchema = z.object({
  messageId: z.string(),
  channelId: z.string(),
  chatType: z.string(),
  chatId: z.string(),
  dateTime: z.string(),
  type: z.string(),
  status: z.string().optional(), // у входящих == "inbound"
  error: z
    .object({ error: z.string(), description: z.string().optional() })
    .nullish(),
  text: z.string().optional(),
  contentUri: z.string().optional(),
  authorName: z.string().optional(),
  authorId: z.string().optional(),
  isEcho: z.boolean(),
  contact: z
    .object({
      name: z.string().optional(),
      avatarUri: z.string().optional(),
      username: z.string().optional(),
      phone: z.string().optional(),
    })
    .optional(),
  quotedMessage: z.unknown().optional(),
  sentFromApp: z.boolean().optional(),
  isEdited: z.boolean().optional(),
  isDeleted: z.boolean().optional(),
  oldInfo: z
    .object({
      oldText: z.string().optional(),
      oldAuthorId: z.string().optional(),
      oldAuthorName: z.string().optional(),
    })
    .optional(),
});
export type WebhookMessage = z.infer<typeof WebhookMessageSchema>;

// --- Webhook payload: статусы исходящих (statuses) ---
// §1, п.6: поле называется timestamp (не dateTime).
export const WebhookStatusSchema = z.object({
  messageId: z.string(),
  timestamp: z.string().optional(),
  status: z.enum(["sent", "delivered", "read", "error", "edited"]).or(z.string()),
  error: z
    .object({
      error: z.string(),
      description: z.string().optional(),
      data: z.unknown().optional(),
    })
    .nullish(),
});
export type WebhookStatus = z.infer<typeof WebhookStatusSchema>;

// --- Webhook payload: обновления каналов (channelsUpdates) ---
export const WebhookChannelUpdateSchema = z.object({
  channelId: z.string(),
  state: z.string(),
  tier: z.string().optional(),
  qr: z.string().optional(),
  qridle: z.string().optional(),
  timestamp: z.number().optional(),
});
export type WebhookChannelUpdate = z.infer<typeof WebhookChannelUpdateSchema>;

/**
 * Полный конверт webhook. Все секции опциональны и обрабатываются НЕЗАВИСИМО
 * (ТЗ §6: не использовать if/else, обрабатывать оба массива).
 * `.passthrough()` — не терять неизвестные поля (сырой payload сохраняем целиком).
 */
export const WebhookPayloadSchema = z
  .object({
    test: z.boolean().optional(),
    messages: z.array(WebhookMessageSchema).optional(),
    statuses: z.array(WebhookStatusSchema).optional(),
    channelsUpdates: z.array(WebhookChannelUpdateSchema).optional(),
    createContact: z.unknown().optional(),
    createDeal: z.unknown().optional(),
  })
  .passthrough();
export type WebhookPayload = z.infer<typeof WebhookPayloadSchema>;
