import { randomUUID, createHash } from "node:crypto";
import { prisma } from "@/lib/db";
import { publishRealtime } from "@/lib/realtime/events";
import { enqueueSend } from "@/lib/queue/send-queue";
import { putObject } from "@/lib/storage/s3";

/**
 * Создание исходящего сообщения менеджера (ТЗ §12). Локальное сообщение
 * создаётся со статусом queued и уникальным crmMessageId ДО вызова Wazzup,
 * затем ставится в очередь отправки. channelId/crmUserId задаются ТОЛЬКО на
 * backend (§24), клиент их не передаёт.
 */

export interface CreateOutboundInput {
  organizationId: string;
  conversationId: string;
  userId: string | null;
  text: string;
  /** Локальный id сообщения, на которое отвечаем (§15). */
  replyToMessageId?: string | undefined;
}

export type CreateOutboundResult =
  | { ok: true; messageId: string; crmMessageId: string }
  | { ok: false; error: string; code: "not_found" | "empty" | "invalid_reply" };

export async function createOutboundMessage(
  input: CreateOutboundInput,
): Promise<CreateOutboundResult> {
  const text = input.text?.trim();
  if (!text) return { ok: false, error: "Пустое сообщение", code: "empty" };

  const conversation = await prisma.conversation.findFirst({
    where: { id: input.conversationId, organizationId: input.organizationId },
    select: { id: true, channelId: true, chatType: true, contact: { select: { chatId: true } } },
  });
  if (!conversation) return { ok: false, error: "Диалог не найден", code: "not_found" };

  // Проверяем, что reply ссылается на сообщение этого же диалога (§15).
  if (input.replyToMessageId) {
    const ref = await prisma.message.findFirst({
      where: { id: input.replyToMessageId, conversationId: conversation.id },
      select: { id: true },
    });
    if (!ref) return { ok: false, error: "Цитируемое сообщение не найдено", code: "invalid_reply" };
  }

  const crmMessageId = randomUUID();
  const message = await prisma.message.create({
    data: {
      organizationId: input.organizationId,
      conversationId: conversation.id,
      provider: "wazzup",
      crmMessageId,
      channelId: conversation.channelId,
      chatType: conversation.chatType,
      chatId: conversation.contact.chatId,
      direction: "outbound",
      type: "text",
      text,
      status: "queued",
      authorId: input.userId,
      replyToMessageId: input.replyToMessageId ?? null,
    },
    select: { id: true },
  });

  // Менеджер ответил → локальный счётчик непрочитанных сбрасываем (§12 clearUnanswered).
  await prisma.conversation.update({
    where: { id: conversation.id },
    data: { unreadCount: 0, lastMessageAt: new Date(), lastMessagePreview: text.slice(0, 120) },
  });

  await publishRealtime({
    event: "message.created",
    organizationId: input.organizationId,
    conversationId: conversation.id,
    payload: { messageId: message.id, direction: "outbound", type: "text", text, status: "queued" },
  });

  await enqueueSend(message.id);

  return { ok: true, messageId: message.id, crmMessageId };
}

const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;

function kindForMime(mime: string): string {
  if (mime.startsWith("image/")) return "image";
  if (mime.startsWith("audio/")) return "audio";
  if (mime.startsWith("video/")) return "video";
  return "document";
}

export interface CreateOutboundMediaInput {
  organizationId: string;
  conversationId: string;
  userId: string | null;
  fileName: string;
  mimeType: string;
  bytes: Uint8Array;
  /** Необязательная подпись — уходит ОТДЕЛЬНЫМ сообщением (§14). */
  caption?: string | undefined;
}

export type CreateOutboundMediaResult =
  | { ok: true; messageIds: string[] }
  | { ok: false; error: string; code: "not_found" | "too_big" | "empty" };

/**
 * Отправка вложения менеджером (ТЗ §14): файл сохраняется в наш S3, затем
 * отправляется через contentUri. text и contentUri НЕ идут одним запросом —
 * подпись уходит вторым сообщением с отдельным crmMessageId.
 */
export async function createOutboundMedia(
  input: CreateOutboundMediaInput,
): Promise<CreateOutboundMediaResult> {
  if (input.bytes.byteLength === 0) return { ok: false, error: "Пустой файл", code: "empty" };
  if (input.bytes.byteLength > MAX_UPLOAD_BYTES) return { ok: false, error: "Файл больше 50MB", code: "too_big" };

  const conversation = await prisma.conversation.findFirst({
    where: { id: input.conversationId, organizationId: input.organizationId },
    select: { id: true, channelId: true, chatType: true, contact: { select: { chatId: true } } },
  });
  if (!conversation) return { ok: false, error: "Диалог не найден", code: "not_found" };

  const kind = kindForMime(input.mimeType);
  const crmMessageId = randomUUID();
  const sha256 = createHash("sha256").update(input.bytes).digest("hex");

  const message = await prisma.message.create({
    data: {
      organizationId: input.organizationId,
      conversationId: conversation.id,
      provider: "wazzup",
      crmMessageId,
      channelId: conversation.channelId,
      chatType: conversation.chatType,
      chatId: conversation.contact.chatId,
      direction: "outbound",
      type: kind,
      status: "queued",
      authorId: input.userId,
    },
    select: { id: true },
  });

  // Сразу кладём файл в S3 (storageKey), send-worker сгенерит presigned contentUri.
  const key = `media/${input.organizationId}/out/${message.id}`;
  await putObject(key, input.bytes, input.mimeType);
  await prisma.messageAttachment.create({
    data: {
      messageId: message.id,
      kind,
      mimeType: input.mimeType,
      sizeBytes: input.bytes.byteLength,
      sha256,
      storageKey: key,
      status: "stored",
    },
  });

  await prisma.conversation.update({
    where: { id: conversation.id },
    data: { unreadCount: 0, lastMessageAt: new Date(), lastMessagePreview: `[${kind}] ${input.fileName}` },
  });
  await publishRealtime({
    event: "message.created",
    organizationId: input.organizationId,
    conversationId: conversation.id,
    payload: { messageId: message.id, direction: "outbound", type: kind, status: "queued" },
  });
  await enqueueSend(message.id);

  const messageIds = [message.id];

  // Подпись — отдельным текстовым сообщением (§14).
  const caption = input.caption?.trim();
  if (caption) {
    const textResult = await createOutboundMessage({
      organizationId: input.organizationId,
      conversationId: conversation.id,
      userId: input.userId,
      text: caption,
    });
    if (textResult.ok) messageIds.push(textResult.messageId);
  }

  return { ok: true, messageIds };
}

/**
 * Повторная отправка ранее упавшего сообщения (§13, кнопка «Повторить»).
 * НЕ создаёт новый crmMessageId и новый текст — переиспользует то же сообщение.
 */
export async function retryOutboundMessage(
  organizationId: string,
  messageId: string,
): Promise<{ ok: boolean; error?: string }> {
  const message = await prisma.message.findFirst({
    where: { id: messageId, organizationId, direction: "outbound" },
    select: { id: true, status: true, externalMessageId: true },
  });
  if (!message) return { ok: false, error: "Сообщение не найдено" };
  if (message.externalMessageId) return { ok: false, error: "Сообщение уже отправлено" };
  if (message.status !== "failed") return { ok: false, error: "Повтор доступен только для неотправленных" };

  await prisma.message.update({ where: { id: message.id }, data: { status: "queued" } });
  await enqueueSend(message.id);
  return { ok: true };
}
