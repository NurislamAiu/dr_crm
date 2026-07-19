import { NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { getAuthContext } from "@/lib/auth/context";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /api/conversations/:id/messages — сообщения диалога (для приложения).
 * Диалог проверяется на принадлежность организации (§24: нет доступа к чужому).
 */
export async function GET(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { organizationId } = await getAuthContext();
  const { id } = await params;

  const conversation = await prisma.conversation.findFirst({
    where: { id, organizationId },
    select: { id: true },
  });
  if (!conversation) {
    return NextResponse.json({ error: "not found" }, { status: 404 });
  }

  const url = new URL(req.url);
  const take = Math.min(Number(url.searchParams.get("limit") ?? 50), 200);

  const messages = await prisma.message.findMany({
    where: { conversationId: id },
    orderBy: { createdAt: "asc" },
    take,
    select: {
      id: true,
      direction: true,
      type: true,
      text: true,
      status: true,
      isEdited: true,
      deletedAt: true,
      displayHint: true,
      authorName: true,
      replyToMessageId: true,
      providerDateTime: true,
      createdAt: true,
      attachments: {
        select: { id: true, kind: true, mimeType: true, sizeBytes: true, status: true },
      },
    },
  });

  return NextResponse.json({ messages });
}
