import { Prisma, type MessageStatus } from "@prisma/client";
import { prisma } from "@/lib/db";
import { publishRealtime } from "@/lib/realtime/events";
import type { NormalizedStatus } from "@/lib/wazzup/normalizer";

/**
 * Обработка статуса исходящего сообщения (ТЗ §17). Не создаёт новых сообщений —
 * только обновляет существующее и пишет историю статусов. Сами исходящие
 * создаёт Этап 5; здесь — forward-compatible обработка webhook statuses.
 */

const STATUS_MAP: Record<string, MessageStatus> = {
  sent: "sent",
  delivered: "delivered",
  read: "read",
  error: "failed",
};

export type StatusOutcome = "updated" | "history_only" | "message_not_found";

export async function processStatus(
  s: NormalizedStatus,
  organizationId: string,
): Promise<StatusOutcome> {
  const message = await prisma.message.findUnique({
    where: { provider_externalMessageId: { provider: "wazzup", externalMessageId: s.externalMessageId } },
    select: { id: true, conversationId: true, status: true },
  });

  // История статусов пишется всегда, когда сообщение найдено.
  if (!message) {
    // Сообщение ещё не создано (например, гонка с ответом Wazzup). Не теряем факт:
    // Этап 5 свяжет по crmMessageId; пока просто сигнализируем, что не нашли.
    return "message_not_found";
  }

  await prisma.messageStatusHistory.create({
    data: {
      messageId: message.id,
      status: s.status,
      providerTimestamp: s.timestamp ? new Date(s.timestamp) : null,
      errorCode: s.errorCode,
      errorDescription: s.errorDescription,
      rawPayload: s.raw as unknown as Prisma.InputJsonValue,
    },
  });

  const mapped = STATUS_MAP[s.status];
  if (mapped) {
    await prisma.message.update({ where: { id: message.id }, data: { status: mapped } });
    await publishRealtime({
      event: "message.status.updated",
      organizationId,
      conversationId: message.conversationId,
      payload: { messageId: message.id, status: mapped, errorCode: s.errorCode },
    });
    return "updated";
  }
  return "history_only";
}
