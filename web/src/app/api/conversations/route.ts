import { NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { getAuthContext, unauthorized } from "@/lib/auth/context";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /api/conversations — список диалогов организации (для приложения).
 * Возвращает контакт, последнее сообщение, unread, ответственного (§18).
 */
export async function GET(req: Request): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  const { organizationId } = ctx;
  const url = new URL(req.url);
  const status = url.searchParams.get("status"); // open|pending|closed
  const take = Math.min(Number(url.searchParams.get("limit") ?? 30), 100);

  const conversations = await prisma.conversation.findMany({
    where: {
      organizationId,
      ...(status === "open" || status === "pending" || status === "closed" ? { status } : {}),
    },
    orderBy: [{ lastMessageAt: "desc" }, { createdAt: "desc" }],
    take,
    select: {
      id: true,
      status: true,
      unreadCount: true,
      lastMessageAt: true,
      lastMessagePreview: true,
      channelId: true,
      assignedUser: { select: { id: true, name: true } },
      contact: { select: { id: true, name: true, phone: true, chatId: true, avatarUri: true } },
    },
  });

  return NextResponse.json({ conversations });
}
