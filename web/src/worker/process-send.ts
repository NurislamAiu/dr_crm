import { prisma } from "@/lib/db";
import { logger } from "@/lib/logger";
import { publishRealtime } from "@/lib/realtime/events";
import { getWazzupClient } from "@/lib/wazzup/factory";
import { resolveSendableChannel } from "@/lib/wazzup/channel-guard";
import { WazzupApiError, WazzupTimeoutError } from "@/lib/wazzup/errors";
import { signedGetUrl } from "@/lib/storage/s3";
import type { WazzupApiClient } from "@/lib/wazzup/client";

/**
 * Отправка одного исходящего сообщения (ТЗ §12, §13, §17).
 * Идемпотентна: переиспользует crmMessageId сообщения. Бросает ошибку только
 * для безопасного авто-ретрая BullMQ (сеть/таймаут/429/5xx с тем же crmMessageId).
 */

export type SendOutcome = "accepted" | "already_sent" | "blocked" | "failed" | "skipped";

async function markStatus(
  messageId: string,
  organizationId: string,
  conversationId: string,
  status: "sending" | "accepted" | "failed",
  extra: { externalMessageId?: string; error?: string } = {},
): Promise<void> {
  await prisma.message.update({
    where: { id: messageId },
    data: {
      status,
      ...(extra.externalMessageId ? { externalMessageId: extra.externalMessageId } : {}),
    },
  });
  await publishRealtime({
    event: "message.status.updated",
    organizationId,
    conversationId,
    payload: { messageId, status, error: extra.error ?? null },
  });
}

export async function processSend(
  messageId: string,
  client: WazzupApiClient = getWazzupClient(),
): Promise<SendOutcome> {
  const message = await prisma.message.findUnique({
    where: { id: messageId },
    select: {
      id: true, organizationId: true, conversationId: true, channelId: true, chatType: true,
      chatId: true, text: true, crmMessageId: true, externalMessageId: true, status: true,
      authorId: true, replyToMessageId: true,
      attachments: { where: { status: "stored" }, select: { storageKey: true }, take: 1 },
    },
  });
  if (!message || !message.crmMessageId) return "skipped";

  // Идемпотентность: уже отправлено (есть Wazzup id) — ничего не делаем.
  if (message.externalMessageId) return "already_sent";
  if (message.status === "accepted" || message.status === "sent" || message.status === "delivered" || message.status === "read") {
    return "already_sent";
  }

  await markStatus(message.id, message.organizationId, message.conversationId, "sending");

  // Проверка состояния канала (§5, §12) — если не active, не отправляем.
  const guard = await resolveSendableChannel(client);
  if (!guard.canSend) {
    await markStatus(message.id, message.organizationId, message.conversationId, "failed", {
      error: guard.reason ?? "Канал недоступен",
    });
    logger.warn("send: канал недоступен, отправка заблокирована", {
      messageId, state: guard.state, reason: guard.reason,
    });
    return "blocked";
  }

  // refMessageId для ответа — только Wazzup messageId (§15).
  let refMessageId: string | undefined;
  if (message.replyToMessageId) {
    const ref = await prisma.message.findUnique({
      where: { id: message.replyToMessageId },
      select: { externalMessageId: true },
    });
    refMessageId = ref?.externalMessageId ?? undefined;
  }

  try {
    const attachmentKey = message.attachments[0]?.storageKey ?? null;
    const common = {
      channelId: message.channelId,
      chatId: message.chatId,
      chatType: message.chatType,
      crmMessageId: message.crmMessageId,
      clearUnanswered: true,
      ...(message.authorId ? { crmUserId: message.authorId } : {}),
    };

    let res;
    if (attachmentKey) {
      // Медиа: presigned URL нашего S3 как contentUri (§14, без text одновременно).
      // Wazzup скачивает сразу, поэтому TTL можно короткий.
      const contentUri = await signedGetUrl(attachmentKey, 600);
      res = await client.sendMediaMessage({ ...common, contentUri });
    } else {
      const base = { ...common, text: message.text ?? "" };
      res = refMessageId
        ? await client.replyToMessage({ ...base, refMessageId })
        : await client.sendTextMessage(base);
    }

    await markStatus(message.id, message.organizationId, message.conversationId, "accepted", {
      externalMessageId: res.messageId,
    });
    logger.info("send: принято Wazzup", { messageId, externalMessageId: res.messageId });
    return "accepted";
  } catch (err) {
    if (err instanceof WazzupApiError) {
      // Повтор crmMessageId → вероятно уже было отправлено ранее (§13). Не дублируем.
      if (err.isRepeatedCrmMessageId) {
        await markStatus(message.id, message.organizationId, message.conversationId, "accepted");
        logger.info("send: REPEATED_CRM_MESSAGE_ID — считаем принятым, без дубля", { messageId });
        return "already_sent";
      }
      // 429/5xx — безопасно ретраить тем же crmMessageId → отдаём ошибку BullMQ.
      if (err.isRetryable) {
        logger.warn("send: временная ошибка, будет ретрай", { messageId, status: err.httpStatus });
        throw err;
      }
      // Прочие 4xx — окончательная ошибка, ретрай бесполезен.
      await markStatus(message.id, message.organizationId, message.conversationId, "failed", {
        error: err.userFacingMessage(),
      });
      logger.error("send: ошибка отправки", { messageId, code: err.code, requestId: err.requestId });
      return "failed";
    }
    if (err instanceof WazzupTimeoutError) {
      // Таймаут — ретрай тем же crmMessageId (§13).
      logger.warn("send: таймаут, будет ретрай", { messageId });
      throw err;
    }
    throw err;
  }
}
