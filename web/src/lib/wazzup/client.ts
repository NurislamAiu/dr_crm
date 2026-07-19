import { z } from "zod";
import { logger, maskSecret } from "../logger";
import { WazzupApiError, WazzupTimeoutError } from "./errors";
import {
  ChannelsResponseSchema,
  SendMessageResponseSchema,
  WazzupErrorBodySchema,
  WebhookSettingsSchema,
  WazzupUsersResponseSchema,
  type Channel,
  type SendMessageResponse,
  type WebhookSettings,
  type WebhookSubscriptions,
  type WazzupUser,
  type WazzupContact,
} from "./schemas";

/**
 * Серверный клиент Wazzup User API v3. ВСЕ вызовы Wazzup проходят через него.
 * Никогда не использовать из браузера (ТЗ §1, §4).
 *
 * Каждый запрос: Authorization: Bearer <apiKey>, Content-Type: application/json,
 * timeout, Zod-валидация ответа, маскирование ключа в логах, сохранение
 * requestId при ошибках, обработка 400/401/403/429/500, retry только для
 * безопасных (идемпотентных) методов.
 */

export interface WazzupClientConfig {
  baseUrl: string;
  apiKey: string;
  /** Таймаут одного запроса, мс. */
  timeoutMs?: number;
  /** Число повторов для безопасных запросов при 429/5xx/сети. */
  maxRetries?: number;
  /** Инъекция fetch для тестов. */
  fetchImpl?: typeof fetch;
}

interface RequestOptions {
  method: "GET" | "POST" | "PATCH" | "DELETE";
  path: string;
  body?: unknown;
  /** Разрешён ли автоматический retry (только для идемпотентных операций!). */
  retryable: boolean;
  correlationId?: string | undefined;
}

const MAX_ENTITIES_PER_REQUEST = 100; // ТЗ §26 / docs: POST users|contacts ≤ 100
const DEFAULT_TIMEOUT_MS = 15_000;
const DEFAULT_MAX_RETRIES = 2;

export class WazzupApiClient {
  private readonly baseUrl: string;
  private readonly apiKey: string;
  private readonly timeoutMs: number;
  private readonly maxRetries: number;
  private readonly fetchImpl: typeof fetch;

  constructor(config: WazzupClientConfig) {
    this.baseUrl = config.baseUrl.replace(/\/+$/, "");
    this.apiKey = config.apiKey;
    this.timeoutMs = config.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.maxRetries = config.maxRetries ?? DEFAULT_MAX_RETRIES;
    this.fetchImpl = config.fetchImpl ?? fetch;
  }

  // ------------------------------------------------------------------
  // Публичные методы (ТЗ §4)
  // ------------------------------------------------------------------

  /** GET /v3/channels — список каналов. */
  async getChannels(correlationId?: string): Promise<Channel[]> {
    return this.request(
      { method: "GET", path: "/v3/channels", retryable: true, correlationId },
      ChannelsResponseSchema,
    );
  }

  /** Быстрая проверка связи/ключа: вызывает getChannels и не бросает. */
  async testConnection(
    correlationId?: string,
  ): Promise<{ ok: true; channels: Channel[] } | { ok: false; error: string; httpStatus?: number }> {
    try {
      const channels = await this.getChannels(correlationId);
      return { ok: true, channels };
    } catch (err) {
      if (err instanceof WazzupApiError)
        return { ok: false, error: err.userFacingMessage(), httpStatus: err.httpStatus };
      if (err instanceof WazzupTimeoutError) return { ok: false, error: "Таймаут соединения с Wazzup" };
      return { ok: false, error: "Не удалось соединиться с Wazzup" };
    }
  }

  /**
   * POST /v3/message — отправка текста.
   * ВАЖНО: не идемпотентен без crmMessageId. retryable=false — повтор только
   * управляемо снаружи с тем же crmMessageId (ТЗ §13).
   */
  async sendTextMessage(input: {
    channelId: string;
    chatId: string;
    text: string;
    chatType?: string;
    crmUserId?: string;
    crmMessageId: string;
    clearUnanswered?: boolean;
    correlationId?: string;
  }): Promise<SendMessageResponse> {
    const { correlationId, chatType, ...rest } = input;
    return this.request(
      {
        method: "POST",
        path: "/v3/message",
        retryable: false,
        correlationId,
        body: { chatType: chatType ?? "whatsapp", ...rest },
      },
      SendMessageResponseSchema,
    );
  }

  /**
   * POST /v3/message — отправка вложения по ссылке contentUri.
   * text и contentUri нельзя передавать одновременно (docs / §14).
   */
  async sendMediaMessage(input: {
    channelId: string;
    chatId: string;
    contentUri: string;
    chatType?: string;
    crmUserId?: string;
    crmMessageId: string;
    clearUnanswered?: boolean;
    correlationId?: string;
  }): Promise<SendMessageResponse> {
    const { correlationId, chatType, ...rest } = input;
    return this.request(
      {
        method: "POST",
        path: "/v3/message",
        retryable: false,
        correlationId,
        body: { chatType: chatType ?? "whatsapp", ...rest },
      },
      SendMessageResponseSchema,
    );
  }

  /**
   * POST /v3/message с refMessageId — ответ (цитирование).
   * refMessageId — это Wazzup messageId, НЕ локальный id (ТЗ §15).
   */
  async replyToMessage(input: {
    channelId: string;
    chatId: string;
    text: string;
    refMessageId: string;
    chatType?: string;
    crmUserId?: string;
    crmMessageId: string;
    clearUnanswered?: boolean;
    correlationId?: string;
  }): Promise<SendMessageResponse> {
    const { correlationId, chatType, ...rest } = input;
    return this.request(
      {
        method: "POST",
        path: "/v3/message",
        retryable: false,
        correlationId,
        body: { chatType: chatType ?? "whatsapp", ...rest },
      },
      SendMessageResponseSchema,
    );
  }

  /**
   * PATCH /v3/message/:messageId — редактирование.
   * text и contentUri взаимоисключающие (docs / §16).
   */
  async editMessage(input: {
    messageId: string;
    text?: string;
    contentUri?: string;
    crmUserId?: string;
    correlationId?: string;
  }): Promise<unknown> {
    const { messageId, correlationId, ...body } = input;
    if ((body.text && body.contentUri) || (!body.text && !body.contentUri)) {
      throw new Error("editMessage: нужно ровно одно из полей text | contentUri");
    }
    return this.request(
      {
        method: "PATCH",
        path: `/v3/message/${encodeURIComponent(messageId)}`,
        retryable: false,
        correlationId,
        body,
      },
      z.unknown(),
    );
  }

  /**
   * DELETE /v3/message/:messageId — удаление.
   * ВНИМАНИЕ: поддержку для transport=whatsapp проверить рантайм-ответом
   * перед показом UI-кнопки (architecture.md §1, п.10).
   */
  async deleteMessage(input: { messageId: string; correlationId?: string }): Promise<unknown> {
    return this.request(
      {
        method: "DELETE",
        path: `/v3/message/${encodeURIComponent(input.messageId)}`,
        retryable: false,
        correlationId: input.correlationId,
      },
      z.unknown(),
    );
  }

  /** PATCH /v3/webhooks — настройка подписок и URL. */
  async configureWebhooks(input: {
    webhooksUri: string;
    subscriptions: WebhookSubscriptions;
    correlationId?: string;
  }): Promise<unknown> {
    if (input.webhooksUri.length > 200) {
      throw new Error("webhooksUri не должен превышать 200 символов");
    }
    return this.request(
      {
        method: "PATCH",
        path: "/v3/webhooks",
        retryable: true, // идемпотентная установка настроек
        correlationId: input.correlationId,
        body: { webhooksUri: input.webhooksUri, subscriptions: input.subscriptions },
      },
      z.unknown(),
    );
  }

  /** GET /v3/webhooks — текущие настройки webhook. */
  async getWebhookSettings(correlationId?: string): Promise<WebhookSettings> {
    return this.request(
      { method: "GET", path: "/v3/webhooks", retryable: true, correlationId },
      WebhookSettingsSchema,
    );
  }

  /** POST /v3/users — upsert менеджеров, ≤100 за запрос (батчинг снаружи). */
  async syncUsers(users: WazzupUser[], correlationId?: string): Promise<unknown> {
    if (users.length > MAX_ENTITIES_PER_REQUEST) {
      throw new Error(`syncUsers: не более ${MAX_ENTITIES_PER_REQUEST} пользователей за запрос`);
    }
    return this.request(
      { method: "POST", path: "/v3/users", retryable: true, correlationId, body: users },
      z.unknown(),
    );
  }

  /** GET /v3/users — список активных пользователей Wazzup. */
  async getUsers(correlationId?: string): Promise<{ id: string; name: string }[]> {
    return this.request(
      { method: "GET", path: "/v3/users", retryable: true, correlationId },
      WazzupUsersResponseSchema,
    );
  }

  /** POST /v3/contacts — upsert контактов, ≤100 за запрос (батчинг снаружи). */
  async syncContacts(contacts: WazzupContact[], correlationId?: string): Promise<unknown> {
    if (contacts.length > MAX_ENTITIES_PER_REQUEST) {
      throw new Error(`syncContacts: не более ${MAX_ENTITIES_PER_REQUEST} контактов за запрос`);
    }
    return this.request(
      { method: "POST", path: "/v3/contacts", retryable: true, correlationId, body: contacts },
      z.unknown(),
    );
  }

  // ------------------------------------------------------------------
  // Ядро: единый защищённый запрос
  // ------------------------------------------------------------------

  private async request<T>(opts: RequestOptions, schema: z.ZodType<T>): Promise<T> {
    const url = `${this.baseUrl}${opts.path}`;
    const maxAttempts = opts.retryable ? this.maxRetries + 1 : 1;

    let lastError: unknown;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        const { status, requestId, json } = await this.doFetch(opts, url);

        if (status >= 200 && status < 300) {
          const parsed = schema.safeParse(json);
          if (!parsed.success) {
            logger.error("Wazzup: ответ не прошёл валидацию схемы", {
              path: opts.path,
              requestId,
              correlationId: opts.correlationId,
              issues: parsed.error.issues.map((i) => i.message),
            });
            throw new WazzupApiError({
              httpStatus: status,
              requestId,
              message: "Некорректный формат ответа Wazzup",
            });
          }
          return parsed.data;
        }

        // Ошибочный HTTP-статус
        const body = WazzupErrorBodySchema.safeParse(json).data;
        const apiError = new WazzupApiError({ httpStatus: status, body, requestId });
        logger.warn("Wazzup: ошибочный ответ", {
          path: opts.path,
          method: opts.method,
          status,
          error: apiError.code,
          description: apiError.description,
          requestId: apiError.requestId,
          correlationId: opts.correlationId,
        });

        if (opts.retryable && apiError.isRetryable && attempt < maxAttempts) {
          await this.backoff(attempt);
          lastError = apiError;
          continue;
        }
        throw apiError;
      } catch (err) {
        if (err instanceof WazzupApiError) throw err;
        // Сетевые/таймаут — ретраим только для безопасных методов
        lastError = err;
        const isTimeout = err instanceof WazzupTimeoutError;
        if (opts.retryable && attempt < maxAttempts) {
          logger.warn("Wazzup: сетевая ошибка, повтор", {
            path: opts.path,
            attempt,
            isTimeout,
            correlationId: opts.correlationId,
          });
          await this.backoff(attempt);
          continue;
        }
        if (isTimeout) throw err;
        throw new WazzupApiError({
          httpStatus: 0,
          message: "Сетевая ошибка при обращении к Wazzup",
        });
      }
    }
    // недостижимо, но для типобезопасности:
    throw lastError instanceof Error ? lastError : new Error("Wazzup request failed");
  }

  private async doFetch(
    opts: RequestOptions,
    url: string,
  ): Promise<{ status: number; requestId: string | undefined; json: unknown }> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = await this.fetchImpl(url, {
        method: opts.method,
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        ...(opts.body !== undefined ? { body: JSON.stringify(opts.body) } : {}),
        signal: controller.signal,
      });

      const requestId = res.headers.get("x-request-id") ?? undefined;
      const text = await res.text();
      let json: unknown = undefined;
      if (text) {
        try {
          json = JSON.parse(text);
        } catch {
          json = text; // не-JSON тело — вернём как есть, схема отвергнет
        }
      }
      return { status: res.status, requestId, json };
    } catch (err) {
      if (err instanceof Error && err.name === "AbortError") {
        throw new WazzupTimeoutError(this.timeoutMs);
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  private backoff(attempt: number): Promise<void> {
    const base = Math.min(1000 * 2 ** (attempt - 1), 4000);
    const jitter = Math.floor(Math.random() * 250);
    return new Promise((r) => setTimeout(r, base + jitter));
  }

  /** Для диагностических логов: замаскированный ключ. */
  get maskedKey(): string {
    return maskSecret(this.apiKey);
  }
}
