import { prisma } from "@/lib/db";
import { publishRealtime } from "@/lib/realtime/events";
import { getWazzupClient } from "@/lib/wazzup/factory";
import { WazzupApiError } from "@/lib/wazzup/errors";

/**
 * Редактирование и удаление ОТПРАВЛЕННЫХ сообщений менеджера (ТЗ §16).
 * Только исходящие, с реальным Wazzup messageId. Если мессенджер/окно времени
 * не позволяет — Wazzup вернёт ошибку, показываем понятный текст, локально не меняем.
 */

export type EditDeleteResult = { ok: true } | { ok: false; error: string; code?: string };

async function findEditableMessage(organizationId: string, messageId: string) {
  return prisma.message.findFirst({
    where: { id: messageId, organizationId, direction: "outbound" },
    select: {
      id: true,
      conversationId: true,
      externalMessageId: true,
      deletedAt: true,
      text: true,
    },
  });
}

/** PATCH /v3/message/:id — изменить текст исходящего. */
export async function editOutboundMessage(
  organizationId: string,
  messageId: string,
  userId: string | null,
  newText: string,
): Promise<EditDeleteResult> {
  const text = newText.trim();
  if (!text) return { ok: false, error: "Пустой текст" };

  const m = await findEditableMessage(organizationId, messageId);
  if (!m) return { ok: false, error: "Сообщение не найдено" };
  if (m.deletedAt) return { ok: false, error: "Сообщение удалено" };
  if (!m.externalMessageId) return { ok: false, error: "Сообщение ещё не отправлено" };

  try {
    await getWazzupClient().editMessage({
      messageId: m.externalMessageId,
      text,
      ...(userId ? { crmUserId: userId } : {}),
    });
  } catch (err) {
    if (err instanceof WazzupApiError) return { ok: false, error: err.userFacingMessage(), code: err.code };
    return { ok: false, error: "Не удалось изменить сообщение" };
  }

  await prisma.message.update({
    where: { id: m.id },
    data: { previousText: m.text, text, isEdited: true, editedAt: new Date() },
  });
  await publishRealtime({
    event: "message.updated",
    organizationId,
    conversationId: m.conversationId,
    payload: { messageId: m.id, isEdited: true, text },
  });
  return { ok: true };
}

/** DELETE /v3/message/:id — удалить исходящее у клиента. */
export async function deleteOutboundMessage(
  organizationId: string,
  messageId: string,
): Promise<EditDeleteResult> {
  const m = await findEditableMessage(organizationId, messageId);
  if (!m) return { ok: false, error: "Сообщение не найдено" };
  if (m.deletedAt) return { ok: true }; // уже удалено — идемпотентно
  if (!m.externalMessageId) return { ok: false, error: "Сообщение ещё не отправлено" };

  try {
    await getWazzupClient().deleteMessage({ messageId: m.externalMessageId });
  } catch (err) {
    if (err instanceof WazzupApiError) return { ok: false, error: err.userFacingMessage(), code: err.code };
    return { ok: false, error: "Не удалось удалить сообщение" };
  }

  await prisma.message.update({
    where: { id: m.id },
    data: { deletedAt: new Date(), displayHint: "Сообщение удалено" },
  });
  await publishRealtime({
    event: "message.updated",
    organizationId,
    conversationId: m.conversationId,
    payload: { messageId: m.id, isDeleted: true },
  });
  return { ok: true };
}
