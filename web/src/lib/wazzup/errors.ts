import type { WazzupErrorBody } from "./schemas.js";

/**
 * Ошибка вызова Wazzup API. Хранит HTTP-статус, requestId и провайдерский код,
 * но НЕ показывается менеджеру напрямую (ТЗ §26). Для UI используем
 * userFacingMessage().
 */
export class WazzupApiError extends Error {
  readonly httpStatus: number;
  readonly code: string | undefined;
  readonly description: string | undefined;
  readonly requestId: string | undefined;
  readonly data: unknown;
  /** Является ли ошибка «повтор crmMessageId» — трактуем как возможную предыдущую успешную отправку. */
  readonly isRepeatedCrmMessageId: boolean;

  constructor(params: {
    httpStatus: number;
    body?: WazzupErrorBody | undefined;
    requestId?: string | undefined;
    message?: string | undefined;
  }) {
    const { httpStatus, body, requestId, message } = params;
    super(message ?? body?.error ?? `Wazzup API error ${httpStatus}`);
    this.name = "WazzupApiError";
    this.httpStatus = httpStatus;
    this.code = body?.error;
    this.description = body?.description;
    this.requestId = requestId ?? body?.requestId;
    this.data = body?.data;
    this.isRepeatedCrmMessageId = body?.error === "REPEATED_CRM_MESSAGE_ID";
  }

  /** Можно ли безопасно повторить запрос (для ретраев safe-методов/сети). */
  get isRetryable(): boolean {
    return this.httpStatus === 429 || this.httpStatus >= 500;
  }

  /** Безопасное сообщение для менеджера (без сырого текста провайдера). */
  userFacingMessage(): string {
    switch (this.code) {
      case "REPEATED_CRM_MESSAGE_ID":
        return "Сообщение уже было отправлено.";
      case "WRONG_TRANSPORT":
        return "Канал не поддерживает этот тип чата.";
      case "INVALID_MESSAGE_DATA":
        return "Некорректные данные сообщения.";
      default:
        if (this.httpStatus === 401 || this.httpStatus === 403)
          return "Ошибка авторизации в Wazzup. Обратитесь к администратору.";
        if (this.httpStatus === 429)
          return "Слишком много запросов. Повторите позже.";
        if (this.httpStatus >= 500)
          return "Временная ошибка сервиса Wazzup. Повторите позже.";
        return "Не удалось отправить сообщение.";
    }
  }
}

/** Таймаут вызова Wazzup. */
export class WazzupTimeoutError extends Error {
  constructor(readonly timeoutMs: number) {
    super(`Wazzup API request timed out after ${timeoutMs}ms`);
    this.name = "WazzupTimeoutError";
  }
}
