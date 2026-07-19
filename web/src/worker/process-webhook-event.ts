import { prisma } from "@/lib/db";
import { logger, maskPhone } from "@/lib/logger";
import { normalizeWebhook, type NormalizedWebhook } from "@/lib/wazzup/normalizer";
import { processInboundMessage } from "@/lib/inbound/process-inbound";
import { processStatus } from "@/lib/inbound/process-status";
import { publishRealtime } from "@/lib/realtime/events";

export interface ProcessResult {
  messages: number;
  newMessages: number;
  statuses: number;
  channelUpdates: number;
}

/**
 * Обработка одного WazzupWebhookEvent (ТЗ §6, §8, §11, §17).
 * messages и statuses обрабатываются НЕЗАВИСИМО. Идемпотентна: повторный
 * прогон не создаёт дублей (Message уникален по provider+externalMessageId).
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
      data: { status: "failed", error: `normalize: ${err instanceof Error ? err.message : String(err)}` },
    });
    throw err;
  }

  let newMessages = 0;

  // --- Ветка 1: messages (независимо от statuses) ---
  for (const m of normalized.messages) {
    const outcome = await processInboundMessage(m, {
      organizationId: event.organizationId,
      webhookEventId: event.id,
    });
    if (outcome.action === "created") newMessages += 1;
    logger.info("worker: сообщение обработано", {
      messageId: m.externalMessageId,
      action: outcome.action,
      direction: m.direction,
      type: m.type,
      chatId: maskPhone(m.chatIdNormalized),
      displayHint: m.displayHint,
    });
  }

  // --- Ветка 2: statuses (независимо от messages) ---
  for (const s of normalized.statuses) {
    const outcome = await processStatus(s, event.organizationId);
    logger.info("worker: статус обработан", {
      messageId: s.externalMessageId,
      status: s.status,
      outcome,
      errorCode: s.errorCode,
    });
  }

  // --- Ветка 3: channelsUpdates ---
  for (const c of normalized.channelUpdates) {
    await prisma.wazzupChannel.updateMany({
      where: { organizationId: event.organizationId, externalChannelId: c.channelId },
      data: { state: c.state, lastCheckedAt: new Date() },
    });
    await publishRealtime({
      event: "channel.state.updated",
      organizationId: event.organizationId,
      payload: { channelId: c.channelId, state: c.state },
    });
    logger.info("worker: обновление канала", { channelId: c.channelId, state: c.state });
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
