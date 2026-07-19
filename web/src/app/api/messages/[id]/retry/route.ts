import { NextResponse } from "next/server";
import { getAuthContext, unauthorized, forbidden, canWrite } from "@/lib/auth/context";
import { retryOutboundMessage } from "@/lib/outbound/send-message";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /api/messages/:id/retry — повтор отправки упавшего сообщения (§13, §17).
 * Переиспользует тот же crmMessageId, нового текста/дубля не создаёт.
 */
export async function POST(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!canWrite(ctx)) return forbidden();
  const { organizationId } = ctx;
  const { id } = await params;

  const result = await retryOutboundMessage(organizationId, id);
  if (!result.ok) {
    return NextResponse.json({ error: result.error }, { status: 400 });
  }
  return NextResponse.json({ status: "queued" }, { status: 202 });
}
