import { prisma } from "@/lib/db";
import { publishRealtime } from "@/lib/realtime/events";

/**
 * Управление диалогом (ТЗ §19): захват, передача, закрытие. Захват атомарен —
 * два менеджера не могут одновременно захватить один диалог (условный UPDATE
 * гарантирует это на уровне БД, транзакционно).
 */

export type ClaimResult =
  | { ok: true; assignedUserId: string }
  | { ok: false; reason: "not_found" | "taken"; assignedUserId?: string };

export async function claimConversation(
  organizationId: string,
  conversationId: string,
  userId: string,
): Promise<ClaimResult> {
  const conv = await prisma.conversation.findFirst({
    where: { id: conversationId, organizationId },
    select: { id: true, assignedUserId: true, status: true },
  });
  if (!conv) return { ok: false, reason: "not_found" };
  if (conv.assignedUserId === userId) return { ok: true, assignedUserId: userId };

  // Атомарный захват: обновляем ТОЛЬКО если ещё не назначен (§19).
  const res = await prisma.conversation.updateMany({
    where: { id: conversationId, organizationId, assignedUserId: null },
    data: { assignedUserId: userId },
  });
  if (res.count === 0) {
    const cur = await prisma.conversation.findUnique({
      where: { id: conversationId },
      select: { assignedUserId: true },
    });
    return { ok: false, reason: "taken", assignedUserId: cur?.assignedUserId ?? undefined };
  }

  await prisma.conversationAssignment.create({ data: { conversationId, userId } });
  await publishRealtime({
    event: "conversation.assigned",
    organizationId,
    conversationId,
    userId,
    payload: { conversationId, assignedUserId: userId },
  });
  return { ok: true, assignedUserId: userId };
}

export async function transferConversation(
  organizationId: string,
  conversationId: string,
  toUserId: string,
  byUserId: string,
): Promise<{ ok: boolean; error?: string }> {
  const conv = await prisma.conversation.findFirst({
    where: { id: conversationId, organizationId },
    select: { id: true },
  });
  if (!conv) return { ok: false, error: "Диалог не найден" };

  const target = await prisma.user.findFirst({
    where: { id: toUserId, organizationId, isActive: true },
    select: { id: true },
  });
  if (!target) return { ok: false, error: "Получатель не найден" };

  await prisma.$transaction([
    prisma.conversationAssignment.updateMany({
      where: { conversationId, active: true },
      data: { active: false, releasedAt: new Date() },
    }),
    prisma.conversation.update({ where: { id: conversationId }, data: { assignedUserId: toUserId } }),
    prisma.conversationAssignment.create({
      data: { conversationId, userId: toUserId, assignedByUserId: byUserId },
    }),
  ]);
  await publishRealtime({
    event: "conversation.assigned",
    organizationId,
    conversationId,
    userId: toUserId,
    payload: { conversationId, assignedUserId: toUserId, transferredBy: byUserId },
  });
  return { ok: true };
}

export async function setConversationStatus(
  organizationId: string,
  conversationId: string,
  status: "open" | "closed",
): Promise<{ ok: boolean }> {
  const res = await prisma.conversation.updateMany({
    where: { id: conversationId, organizationId },
    data: { status },
  });
  if (res.count === 0) return { ok: false };
  await publishRealtime({
    event: "conversation.updated",
    organizationId,
    conversationId,
    payload: { conversationId, status },
  });
  return { ok: true };
}

/** Внутренняя заметка — НИКОГДА не уходит в Wazzup (§19). */
export async function addInternalNote(
  organizationId: string,
  conversationId: string,
  authorUserId: string,
  text: string,
): Promise<{ ok: boolean; noteId?: string; error?: string }> {
  const conv = await prisma.conversation.findFirst({
    where: { id: conversationId, organizationId },
    select: { id: true },
  });
  if (!conv) return { ok: false, error: "Диалог не найден" };

  const note = await prisma.internalNote.create({
    data: { organizationId, conversationId, authorUserId, text: text.trim() },
    select: { id: true },
  });
  await publishRealtime({
    event: "conversation.updated",
    organizationId,
    conversationId,
    payload: { conversationId, note: "added" },
  });
  return { ok: true, noteId: note.id };
}
