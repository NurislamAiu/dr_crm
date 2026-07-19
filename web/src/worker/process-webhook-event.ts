import { prisma } from "@/lib/db";
import { logger, maskPhone } from "@/lib/logger";
import { normalizeWebhook, type NormalizedWebhook } from "@/lib/wazzup/normalizer";

export interface ProcessResult {
  messages: number;
  newMessages: number;
  statuses: number;
  channelUpdates: number;
}

/**
 * Обработка одного WazzupWebhookEvent (ТЗ §6, §8, §11, §17).
 * messages и statuses обрабатываются НЕЗАВИСИМО. Идемпотентна: повторный
 * прогон того же события не создаёт дублей (upsert по provider+externalMessageId).
 */
export async function processWebhookEvent(eventId: string): Promise<ProcessResult> {
  const event = await prisma.wazzupWebhookEvent.findUnique({ where: { id: eventId } });
  if (!event) {
    logger.warn("worker: событие не найдено", { eventId });
    return { messages: 0, newMessages: 0, statuses: 0, channelUpdates: 0 };
  }

  await prisma.wazzupWebhookEvent.update({
    where: { id: eventId },
    data: { status: "processing", attempts: { increment: 1 } },
  });

  let normalized: NormalizedWebhook;
  try {
    normalized = normalizeWebhook(event.rawPayload);
  } catch (err) {
    await prisma.wazzupWebhookEvent.update({
      where: { id: eventId },
      data: {
        status: "failed",
        error: `normalize: ${err instanceof Error ? err.message : String(err)}`,
      },
    });
    throw err;
  }

  let newMessages = 0;

  // --- Ветка 1: messages (независимо от statuses) ---
  for (const m of normalized.messages) {
    const res = await prisma.inboundMessageReceipt.upsert({
      where: { provider_externalMessageId: { provider: "wazzup", externalMessageId: m.externalMessageId } },
      create: {
        organizationId: event.organizationId,
        provider: "wazzup",
        externalMessageId: m.externalMessageId,
        channelId: m.channelId,
        chatType: m.chatType,
        chatId: m.chatIdNormalized,
        direction: m.direction,
        type: m.type,
        hasContent: m.hasContent,
        isEdited: m.isEdited,
        isDeleted: m.isDeleted,
        providerDateTime: m.providerDateTime ? new Date(m.providerDateTime) : null,
        webhookEventId: event.id,
      },
      update: {
        // Повторный webhook по тому же messageId: обновляем изменяемые поля
        // (редактирование/удаление), но не плодим записи (ТЗ §9, §11).
        isEdited: m.isEdited,
        isDeleted: m.isDeleted,
        type: m.type,
        hasContent: m.hasContent,
      },
      select: { createdAt: true, updatedAt: true },
    });
    // Новая запись, если createdAt == updatedAt (только что создана).
    if (res.createdAt.getTime() === res.updatedAt.getTime()) newMessages += 1;

    logger.info("worker: сообщение обработано", {
      messageId: m.externalMessageId,
      direction: m.direction,
      type: m.type,
      rawType: m.rawType,
      chatId: maskPhone(m.chatIdNormalized),
      isEdited: m.isEdited,
      isDeleted: m.isDeleted,
      displayHint: m.displayHint,
    });
    // Этап 3: здесь появится upsert Contact/Conversation/Message + WebSocket.
  }

  // --- Ветка 2: statuses (независимо от messages) ---
  for (const s of normalized.statuses) {
    logger.info("worker: статус обработан", {
      messageId: s.externalMessageId,
      status: s.status,
      errorCode: s.errorCode,
    });
    // Этап 5: обновление Message.status + MessageStatusHistory + WebSocket.
  }

  // --- Ветка 3: channelsUpdates ---
  for (const c of normalized.channelUpdates) {
    logger.info("worker: обновление канала", { channelId: c.channelId, state: c.state });
    // Этап 3/8: обновление WazzupChannel.state + уведомление администратора.
  }

  await prisma.wazzupWebhookEvent.update({
    where: { id: eventId },
    data: { status: "processed", processedAt: new Date(), error: null },
  });

  return {
    messages: normalized.messages.length,
    newMessages,
    statuses: normalized.statuses.length,
    channelUpdates: normalized.channelUpdates.length,
  };
}
