import { NextResponse } from "next/server";
import { getAuthContext, unauthorized } from "@/lib/auth/context";
import { markConversationRead } from "@/lib/conversations/manage";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /api/conversations/:id/read — отметить прочитанным (сброс unreadCount).
 * Вызывается при открытии чата менеджером.
 */
export async function POST(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  const { id } = await params;
  await markConversationRead(ctx.organizationId, id);
  return NextResponse.json({ ok: true });
}
