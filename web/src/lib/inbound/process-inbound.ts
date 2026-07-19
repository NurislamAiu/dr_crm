import { Prisma, type MessageStatus } from "@prisma/client";
import { prisma } from "@/lib/db";
import { publishRealtime } from "@/lib/realtime/events";
import type { NormalizedMessage } from "@/lib/wazzup/normalizer";

/**
 * Пайплайн обработки одного нормализованного сообщения из webhook (ТЗ §11).
 * Идемпотентен по (provider, externalMessageId): повторный webhook не создаёт
 * дублей контакта/сообщения; обрабатывает редактирование и удаление (§9).
 */

export interface InboundContext {
  organizationId: string;
  webhookEventId?: string;
}

export type InboundOutcome =
  | { action: "created"; messageId: string; conversationId: string; contactCreated: boolean; conversationCreated: boolean }
  | { action: "edited" | "deleted"; messageId: string; conversationId: string }
  | { action: "duplicate"; messageId: string; conversationId: string };

/** Форматирование телефона для отображаемого имени, когда имя не пришло (§11 п.5). */
function formatPhone(chatId: string): string {
  const d = chatId.replace(/\D/g, "");
  return d ? `+${d}` : chatId;
}

/** Выбор менеджера для назначения (простая стратегия; round-robin — Этап 7). */
async function pickAssignee(
  tx: Prisma.TransactionClient,
  organizationId: string,
): Promise<string | null> {
  const user = await tx.user.findFirst({
    where: { organizationId, isActive: true, role: { in: ["manager", "admin"] } },
    orderBy: { createdAt: "asc" },
    select: { id: true },
  });
  return user?.id ?? null;
}

export async function processInboundMessage(
  m: NormalizedMessage,
  ctx: InboundContext,
): Promise<InboundOutcome> {
  const isInbound = m.direction === "inbound";

  return prisma.$transaction(async (tx) => {
    // --- 1. Контакт (уникален по org+channel+chatId, без дублей §11) ---
    const displayName = m.contactName?.trim() || formatPhone(m.chatIdNormalized);
    const contactBefore = await tx.contact.findUnique({
      where: {
        organizationId_channelId_chatId: {
          organizationId: ctx.organizationId,
          channelId: m.channelId,
          chatId: m.chatIdNormalized,
        },
      },
      select: { id: true },
    });
    const contact = await tx.contact.upsert({
      where: {
        organizationId_channelId_chatId: {
          organizationId: ctx.organizationId,
          channelId: m.channelId,
          chatId: m.chatIdNormalized,
        },
      },
      create: {
        organizationId: ctx.organizationId,
        channelId: m.channelId,
        chatType: m.chatType,
        chatId: m.chatIdNormalized,
        name: displayName,
        phone: m.contactPhone ?? (m.chatType === "whatsapp" ? m.chatIdNormalized : null),
      },
      // На повторном webhook имя обновляем только если пришло непустое (не портим §11 п.4).
      update: m.contactName?.trim() ? { name: m.contactName.trim() } : {},
      select: { id: true },
    });
    const contactCreated = !contactBefore;

    // --- 2. Открытый диалог (иначе создать §11 п.6-7) ---
    let conversation = await tx.conversation.findFirst({
      where: { organizationId: ctx.organizationId, contactId: contact.id, status: { not: "closed" } },
      orderBy: { createdAt: "desc" },
      select: { id: true, unreadCount: true, assignedUserId: true },
    });
    let conversationCreated = false;
    if (!conversation) {
      conversation = await tx.conversation.create({
        data: {
          organizationId: ctx.organizationId,
          contactId: contact.id,
          channelId: m.channelId,
          chatType: m.chatType,
          status: "open",
        },
        select: { id: true, unreadCount: true, assignedUserId: true },
      });
      conversationCreated = true;
    }

    // --- 3. Дедуп сообщения по (provider, externalMessageId) ---
    const existing = await tx.message.findUnique({
      where: { provider_externalMessageId: { provider: "wazzup", externalMessageId: m.externalMessageId } },
      select: { id: true, text: true, deletedAt: true, isEdited: true },
    });

    if (existing) {
      // Удаление (§9): не удаляем физически, ставим deletedAt.
      if (m.isDeleted && !existing.deletedAt) {
        await tx.message.update({
          where: { id: existing.id },
          data: { deletedAt: new Date(), displayHint: "Сообщение удалено" },
        });
        await publishRealtime({
          event: "message.updated",
          organizationId: ctx.organizationId,
          conversationId: conversation.id,
          payload: { messageId: existing.id, isDeleted: true },
        });
        return { action: "deleted", messageId: existing.id, conversationId: conversation.id };
      }
      // Редактирование (§9): сохранить старый текст, обновить.
      if (m.isEdited && m.text !== null && m.text !== existing.text) {
        await tx.message.update({
          where: { id: existing.id },
          data: { previousText: existing.text, text: m.text, isEdited: true, editedAt: new Date() },
        });
        await publishRealtime({
          event: "message.updated",
          organizationId: ctx.organizationId,
          conversationId: conversation.id,
          payload: { messageId: existing.id, isEdited: true, text: m.text },
        });
        return { action: "edited", messageId: existing.id, conversationId: conversation.id };
      }
      return { action: "duplicate", messageId: existing.id, conversationId: conversation.id };
    }

    // --- 4. Создать сообщение ---
    const status: MessageStatus = isInbound ? "inbound" : "sent";
    let message;
    try {
      message = await tx.message.create({
        data: {
          organizationId: ctx.organizationId,
          conversationId: conversation.id,
          provider: "wazzup",
          externalMessageId: m.externalMessageId,
          channelId: m.channelId,
          chatType: m.chatType,
          chatId: m.chatIdNormalized,
          direction: m.direction,
          type: m.type,
          rawType: m.rawType,
          text: m.text,
          status,
          isEdited: m.isEdited,
          deletedAt: m.isDeleted ? new Date() : null,
          authorName: m.authorName,
          authorId: m.authorId,
          displayHint: m.displayHint,
          providerDateTime: m.providerDateTime ? new Date(m.providerDateTime) : null,
          ...(ctx.webhookEventId ? { webhookEventId: ctx.webhookEventId } : {}),
          rawPayload: m.raw as unknown as Prisma.InputJsonValue,
        },
        select: { id: true },
      });
    } catch (err) {
      // Гонка одинаковых webhook: параллельный create того же messageId.
      if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002") {
        const dup = await tx.message.findUnique({
          where: { provider_externalMessageId: { provider: "wazzup", externalMessageId: m.externalMessageId } },
          select: { id: true },
        });
        return { action: "duplicate", messageId: dup?.id ?? "", conversationId: conversation.id };
      }
      throw err;
    }

    // --- 5. Обновить диалог: превью, время, unread (только входящие) ---
    const preview = m.displayHint ?? (m.text ? m.text.slice(0, 120) : "[вложение]");
    let assignedUserId = conversation.assignedUserId;
    if (isInbound && !assignedUserId) {
      assignedUserId = await pickAssignee(tx, ctx.organizationId);
    }
    await tx.conversation.update({
      where: { id: conversation.id },
      data: {
        lastMessageAt: m.providerDateTime ? new Date(m.providerDateTime) : new Date(),
        lastMessagePreview: preview,
        ...(isInbound ? { unreadCount: { increment: 1 } } : {}),
        ...(assignedUserId && !conversation.assignedUserId ? { assignedUserId } : {}),
      },
    });

    // Назначение (запись истории + realtime), если только что назначили.
    if (assignedUserId && !conversation.assignedUserId) {
      await tx.conversationAssignment.create({
        data: { conversationId: conversation.id, userId: assignedUserId },
      });
      await publishRealtime({
        event: "conversation.assigned",
        organizationId: ctx.organizationId,
        conversationId: conversation.id,
        userId: assignedUserId,
        payload: { conversationId: conversation.id, assignedUserId },
      });
    }

    // --- 6. Notification (входящие) ---
    if (isInbound && assignedUserId) {
      await tx.notification.create({
        data: {
          organizationId: ctx.organizationId,
          userId: assignedUserId,
          type: "new_message",
          conversationId: conversation.id,
          messageId: message.id,
          payload: { preview },
        },
      });
      await publishRealtime({
        event: "notification.created",
        organizationId: ctx.organizationId,
        userId: assignedUserId,
        payload: { conversationId: conversation.id, messageId: message.id, preview },
      });
    }

    // --- 7. Audit log ---
    await tx.auditLog.create({
      data: {
        organizationId: ctx.organizationId,
        actorType: "system",
        action: isInbound ? "inbound_message_received" : "outbound_echo_received",
        entityType: "Message",
        entityId: message.id,
        metadata: { externalMessageId: m.externalMessageId, type: m.type },
      },
    });

    // --- 8. Realtime ---
    if (conversationCreated) {
      await publishRealtime({
        event: "conversation.created",
        organizationId: ctx.organizationId,
        conversationId: conversation.id,
        payload: { conversationId: conversation.id, contactId: contact.id },
      });
    }
    await publishRealtime({
      event: "message.created",
      organizationId: ctx.organizationId,
      conversationId: conversation.id,
      payload: {
        messageId: message.id,
        conversationId: conversation.id,
        direction: m.direction,
        type: m.type,
        text: m.text,
        displayHint: m.displayHint,
      },
    });
    await publishRealtime({
      event: "conversation.updated",
      organizationId: ctx.organizationId,
      conversationId: conversation.id,
      payload: { conversationId: conversation.id, lastMessagePreview: preview },
    });

    return {
      action: "created",
      messageId: message.id,
      conversationId: conversation.id,
      contactCreated,
      conversationCreated,
    };
  });
}
