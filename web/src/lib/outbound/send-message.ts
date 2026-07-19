import { randomUUID } from "node:crypto";
import { prisma } from "@/lib/db";
import { publishRealtime } from "@/lib/realtime/events";
import { enqueueSend } from "@/lib/queue/send-queue";

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
