/**
 * Тонкий клиент Telegram Bot API. Все вызовы — только с сервера (токен из
 * Secret Manager). Файлы отправляются multipart'ом из байтов нашего Storage —
 * публичные ссылки не нужны, ссылки Telegram с токеном наружу не отдаются.
 */

// ── Типы апдейтов (только используемые поля) ──────────────────────────────

export interface TgUser {
  id: number;
  first_name?: string;
  last_name?: string;
  username?: string;
}

export interface TgChat {
  id: number;
  type?: string; // private | group | supergroup | channel
  first_name?: string;
  last_name?: string;
  username?: string;
}

export interface TgFileRef {
  file_id: string;
  file_name?: string;
  mime_type?: string;
  file_size?: number;
}

export interface TgContact {
  phone_number?: string;
  first_name?: string;
  user_id?: number;
}

export interface TgSticker {
  file_id: string;
  emoji?: string;
  is_animated?: boolean;
  is_video?: boolean;
}

export interface TgMessage {
  message_id: number;
  date?: number;
  edit_date?: number;
  chat?: TgChat;
  from?: TgUser;
  text?: string;
  caption?: string;
  contact?: TgContact;
  photo?: TgFileRef[]; // размеры по возрастанию, последний — самый большой
  document?: TgFileRef;
  voice?: TgFileRef;
  audio?: TgFileRef;
  video?: TgFileRef;
  video_note?: TgFileRef;
  sticker?: TgSticker;
  location?: unknown;
  business_connection_id?: string;
}

export interface TgChatMemberUpdated {
  chat?: TgChat;
  from?: TgUser;
  new_chat_member?: { status?: string };
}

export interface TgCallbackQuery {
  id?: string;
  from?: TgUser;
  message?: TgMessage;
  data?: string;
}

export interface TgUpdate {
  update_id?: number;
  message?: TgMessage;
  edited_message?: TgMessage;
  callback_query?: TgCallbackQuery;
  // Telegram Business (личный аккаунт) — заложено на будущее.
  business_message?: TgMessage;
  edited_business_message?: TgMessage;
  deleted_business_messages?: {
    business_connection_id?: string;
    chat?: TgChat;
    message_ids?: number[];
  };
  my_chat_member?: TgChatMemberUpdated;
}

// ── Ошибки и низкоуровневый вызов ─────────────────────────────────────────

/** Ошибка Bot API: код, описание и retry_after для 429. */
export class TgApiError extends Error {
  constructor(
    public readonly code: number,
    public readonly description: string,
    public readonly retryAfter: number | null,
  ) {
    super(`Telegram ${code}: ${description}`);
  }

  /** Клиент заблокировал бота (или удалил аккаунт) — писать ему нельзя. */
  get blockedByUser(): boolean {
    return this.code === 403;
  }
}

const BASE = "https://api.telegram.org";

async function parseResponse<T>(res: Response): Promise<T> {
  const body = (await res.json().catch(() => ({}))) as {
    ok?: boolean;
    result?: T;
    error_code?: number;
    description?: string;
    parameters?: { retry_after?: number };
  };
  if (body.ok === true && body.result !== undefined) return body.result;
  const retryAfter =
    typeof body.parameters?.retry_after === "number" ? body.parameters.retry_after : null;
  throw new TgApiError(body.error_code ?? res.status, body.description ?? "unknown error", retryAfter);
}

/** Вызов метода Bot API с JSON-параметрами. */
export async function tgCall<T>(token: string, method: string, payload: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${BASE}/bot${token}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  return parseResponse<T>(res);
}

// ── Методы ────────────────────────────────────────────────────────────────

/** sendMessage: текст клиенту. replyToMessageId — ответ (цитата). */
export function tgSendTextApi(
  token: string,
  p: {
    chatId: number | string;
    text: string;
    replyToMessageId?: number;
    replyMarkup?: unknown;
  },
): Promise<TgMessage> {
  return tgCall<TgMessage>(token, "sendMessage", {
    chat_id: p.chatId,
    text: p.text,
    ...(p.replyToMessageId
      ? { reply_parameters: { message_id: p.replyToMessageId, allow_sending_without_reply: true } }
      : {}),
    ...(p.replyMarkup ? { reply_markup: p.replyMarkup } : {}),
  });
}

/** sendChatAction: клиент видит «печатает…», пока менеджер набирает ответ. */
export function tgChatAction(token: string, chatId: number | string): Promise<boolean> {
  return tgCall<boolean>(token, "sendChatAction", { chat_id: chatId, action: "typing" });
}

/**
 * Отправка файла multipart'ом. Telegram привередлив к форматам photo/video/
 * audio — при 400 перепосылаем тот же файл документом (доходит всегда).
 */
export async function tgSendMediaBytes(
  token: string,
  p: {
    chatId: number | string;
    kind: string; // image | video | audio | document
    bytes: Buffer;
    fileName: string;
    contentType?: string;
  },
): Promise<TgMessage> {
  const byKind: Record<string, [string, string]> = {
    image: ["sendPhoto", "photo"],
    video: ["sendVideo", "video"],
    audio: ["sendAudio", "audio"],
    document: ["sendDocument", "document"],
  };
  const [method, field] = byKind[p.kind] ?? ["sendDocument", "document"];

  const send = async (m: string, f: string): Promise<TgMessage> => {
    const form = new FormData();
    form.set("chat_id", String(p.chatId));
    // Копия в Uint8Array: Blob не принимает Buffer с ArrayBufferLike напрямую.
    form.set(f, new Blob([new Uint8Array(p.bytes)], { type: p.contentType ?? "application/octet-stream" }), p.fileName);
    const res = await fetch(`${BASE}/bot${token}/${m}`, { method: "POST", body: form });
    return parseResponse<TgMessage>(res);
  };

  try {
    return await send(method, field);
  } catch (e) {
    if (e instanceof TgApiError && e.code === 400 && method !== "sendDocument") {
      return send("sendDocument", "document");
    }
    throw e;
  }
}

/**
 * getFile + скачивание. Ссылка Telegram живёт ограниченное время и содержит
 * токен бота — наружу её не отдаём, файл сразу перекладывается в наш Storage.
 * Ограничение Bot API: файлы больше 20 МБ боту не отдаются.
 */
export async function tgDownloadFile(
  token: string,
  fileId: string,
): Promise<{ bytes: Buffer; contentType: string | null }> {
  const info = await tgCall<{ file_path?: string }>(token, "getFile", { file_id: fileId });
  if (!info.file_path) throw new Error("getFile: пустой file_path");
  const res = await fetch(`${BASE}/file/bot${token}/${info.file_path}`);
  if (!res.ok) throw new Error(`Скачивание файла Telegram: HTTP ${res.status}`);
  return { bytes: Buffer.from(await res.arrayBuffer()), contentType: res.headers.get("content-type") };
}

/** editMessageText: правка нашего исходящего. */
export function tgEditTextApi(
  token: string,
  p: { chatId: number | string; messageId: number; text: string },
): Promise<unknown> {
  return tgCall<unknown>(token, "editMessageText", {
    chat_id: p.chatId,
    message_id: p.messageId,
    text: p.text,
  });
}

/** deleteMessage: удаление у клиента (Telegram даёт ~48 часов). */
export function tgDeleteMessageApi(
  token: string,
  chatId: number | string,
  messageId: number,
): Promise<boolean> {
  return tgCall<boolean>(token, "deleteMessage", { chat_id: chatId, message_id: messageId });
}

/** answerCallbackQuery: убрать «часики» на инлайн-кнопке. */
export function tgAnswerCallback(token: string, callbackQueryId: string): Promise<boolean> {
  return tgCall<boolean>(token, "answerCallbackQuery", { callback_query_id: callbackQueryId });
}
