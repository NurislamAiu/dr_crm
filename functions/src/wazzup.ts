/** chatId для whatsapp — только цифры (как в текущем backend). */
export function normalizeChatId(chatType: string, chatId: string): string {
  if (chatType === "whatsapp") return chatId.replace(/\D/g, "");
  return chatId.trim();
}

/** Дата сообщения Wazzup (ISO) → миллисекунды, либо null. */
export function parseDateMs(v: unknown): number | null {
  if (typeof v !== "string") return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
}

export interface WazzupMessage {
  messageId?: string;
  chatId?: string;
  chatType?: string;
  type?: string;
  text?: string | null;
  contentUri?: string | null;
  isEcho?: boolean;
  status?: string;
  dateTime?: string;
  authorName?: string | null;
  channelId?: string;
}

export interface WazzupStatus {
  messageId?: string;
  status?: string;
  timestamp?: string;
}

/** POST /v3/message — отправка текста через Wazzup. Возвращает messageId. */
export async function wazzupSendText(
  apiKey: string,
  input: { channelId: string; chatId: string; chatType: string; text: string; crmMessageId: string; refMessageId?: string },
): Promise<{ messageId?: string }> {
  const res = await fetch("https://api.wazzup24.com/v3/message", {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({
      channelId: input.channelId,
      chatId: input.chatId,
      chatType: input.chatType,
      text: input.text,
      crmMessageId: input.crmMessageId,
      ...(input.refMessageId ? { refMessageId: input.refMessageId } : {}),
      clearUnanswered: true,
    }),
  });
  const data = (await res.json().catch(() => ({}))) as { messageId?: string; error?: unknown };
  if (!res.ok) throw new Error(`Wazzup ${res.status}: ${JSON.stringify(data)}`);
  return { messageId: data.messageId };
}

/** PATCH /v3/message/:id — редактирование текста. */
export async function wazzupEditText(apiKey: string, messageId: string, text: string): Promise<void> {
  const res = await fetch(`https://api.wazzup24.com/v3/message/${encodeURIComponent(messageId)}`, {
    method: "PATCH",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({ text }),
  });
  if (!res.ok) throw new Error(`Wazzup edit ${res.status}: ${await res.text()}`);
}

/** DELETE /v3/message/:id — удаление. */
export async function wazzupDeleteMessage(apiKey: string, messageId: string): Promise<void> {
  const res = await fetch(`https://api.wazzup24.com/v3/message/${encodeURIComponent(messageId)}`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) throw new Error(`Wazzup delete ${res.status}: ${await res.text()}`);
}

/** POST /v3/message — отправка медиа по публичной ссылке contentUri. */
export async function wazzupSendMedia(
  apiKey: string,
  input: { channelId: string; chatId: string; chatType: string; contentUri: string; crmMessageId: string },
): Promise<{ messageId?: string }> {
  const res = await fetch("https://api.wazzup24.com/v3/message", {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({
      channelId: input.channelId,
      chatId: input.chatId,
      chatType: input.chatType,
      contentUri: input.contentUri,
      crmMessageId: input.crmMessageId,
      clearUnanswered: true,
    }),
  });
  const data = (await res.json().catch(() => ({}))) as { messageId?: string };
  if (!res.ok) throw new Error(`Wazzup ${res.status}: ${JSON.stringify(data)}`);
  return { messageId: data.messageId };
}

/** Тип медиа по MIME → как в приложении (image/audio/video/document). */
export function kindForMime(mime: string): string {
  if (mime.startsWith("image/")) return "image";
  if (mime.startsWith("audio/")) return "audio";
  if (mime.startsWith("video/")) return "video";
  return "document";
}
