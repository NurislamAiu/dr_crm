import { NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { getAuthContext, unauthorized } from "@/lib/auth/context";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const conversationSelect = {
  id: true,
  status: true,
  unreadCount: true,
  lastMessageAt: true,
  lastMessagePreview: true,
  channelId: true,
  assignedUser: { select: { id: true, name: true } },
  contact: { select: { id: true, name: true, phone: true, chatId: true, avatarUri: true } },
} as const;

/**
 * GET /api/search?q=... — поиск по диалогам (номер/имя контакта) и по тексту
 * сообщений. Всё в рамках организации (§24). Регистронезависимо (ILIKE).
 */
export async function GET(req: Request): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();

  const url = new URL(req.url);
  const q = (url.searchParams.get("q") ?? "").trim();
  if (q.length < 1) return NextResponse.json({ conversations: [], messages: [] });
  const qDigits = q.replace(/\D/g, "");

  const [conversations, messages] = await Promise.all([
    prisma.conversation.findMany({
      where: {
        organizationId: ctx.organizationId,
        contact: {
          OR: [
            ...(qDigits ? [{ chatId: { contains: qDigits } }] : []),
            { name: { contains: q, mode: "insensitive" as const } },
          ],
        },
      },
      orderBy: [{ lastMessageAt: "desc" }],
      take: 20,
      select: conversationSelect,
    }),
    prisma.message.findMany({
      where: {
        organizationId: ctx.organizationId,
        deletedAt: null,
        text: { contains: q, mode: "insensitive" },
      },
      orderBy: { createdAt: "desc" },
      take: 30,
      select: {
        id: true,
        text: true,
        direction: true,
        createdAt: true,
        conversation: { select: conversationSelect },
      },
    }),
  ]);

  return NextResponse.json({ conversations, messages });
}
