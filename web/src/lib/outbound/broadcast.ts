import { randomUUID } from "node:crypto";
import { prisma } from "@/lib/db";
import { getEnv } from "@/lib/env";
import { processSend } from "@/worker/process-send";

/**
 * Рассылка сервисных сообщений (напоминания о записи) пациентам, которые уже
 * писали клинике. Одно сообщение = один контакт: находим/создаём контакт и
 * диалог по номеру, создаём исходящее сообщение и отправляем СИНХРОННО через
 * processSend (реальный вызов Wazzup + статус + проверка канала), чтобы вернуть
 * фактический результат для прогресса. Пауза между контактами — на клиенте.
 */

export interface BroadcastOneInput {
  organizationId: string;
  userId: string | null;
  name: string;
  phone: string;
  text: string;
}

export type BroadcastOneResult =
  | { ok: true; status: "sent"; chatId: string; conversationId: string }
  | { ok: false; status: "invalid" | "blocked" | "failed"; error: string; chatId?: string };

/** Нормализация номера в chatId Wazzup (только цифры; 8→7 для 11-значных). */
export function normalizePhone(raw: string): string | null {
  let d = (raw || "").replace(/\D/g, "");
  if (d.length === 11 && d.startsWith("8")) d = "7" + d.slice(1);
  if (d.length < 10 || d.length > 15) return null;
  return d;
}

export async function sendBroadcastMessage(input: BroadcastOneInput): Promise<BroadcastOneResult> {
  const text = input.text?.trim();
  if (!text) return { ok: false, status: "invalid", error: "Пустой текст" };

  const chatId = normalizePhone(input.phone);
  if (!chatId) return { ok: false, status: "invalid", error: `Неверный номер: ${input.phone}` };

  const channelId = getEnv().WAZZUP_CHANNEL_ID;
  if (!channelId) return { ok: false, status: "failed", error: "WAZZUP_CHANNEL_ID не задан", chatId };

  const chatType = "whatsapp";
  const name = input.name?.trim();

  // 1. Контакт по номеру (org+channel+chatId). Имя обновляем, если задано.
  const contact = await prisma.contact.upsert({
    where: { organizationId_channelId_chatId: { organizationId: input.organizationId, channelId, chatId } },
    create: {
      organizationId: input.organizationId,
      channelId,
      chatType,
      chatId,
      name: name && name.length > 0 ? name : `+${chatId}`,
      phone: chatId,
    },
    update: name && name.length > 0 ? { name } : {},
    select: { id: true },
  });

  // 2. Диалог: один на контакт.
  let conversation = await prisma.conversation.findUnique({
    where: { organizationId_contactId: { organizationId: input.organizationId, contactId: contact.id } },
    select: { id: true },
  });
  conversation ??= await prisma.conversation.create({
    data: {
      organizationId: input.organizationId,
      contactId: contact.id,
      channelId,
      chatType,
      status: "open",
    },
    select: { id: true },
  });

  // 3. Исходящее сообщение (queued) + служебные поля.
  const crmMessageId = randomUUID();
  const message = await prisma.message.create({
    data: {
      organizationId: input.organizationId,
      conversationId: conversation.id,
      provider: "wazzup",
      crmMessageId,
      channelId,
      chatType,
      chatId,
      direction: "outbound",
      type: "text",
      text,
      status: "queued",
      authorId: input.userId,
    },
    select: { id: true },
  });
  await prisma.conversation.update({
    where: { id: conversation.id },
    data: { lastMessageAt: new Date(), lastMessagePreview: text.slice(0, 120) },
  });

  // 4. Отправляем синхронно тем же кодом, что и обычная отправка.
  try {
    const outcome = await processSend(message.id);
    if (outcome === "accepted" || outcome === "already_sent") {
      return { ok: true, status: "sent", chatId, conversationId: conversation.id };
    }
    if (outcome === "blocked") {
      return { ok: false, status: "blocked", error: "Канал недоступен", chatId };
    }
    return { ok: false, status: "failed", error: "Не отправлено", chatId };
  } catch (e) {
    return { ok: false, status: "failed", error: e instanceof Error ? e.message : String(e), chatId };
  }
}
