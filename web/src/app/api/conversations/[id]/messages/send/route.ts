import { NextResponse } from "next/server";
import { z } from "zod";
import { getAuthContext } from "@/lib/auth/context";
import { createOutboundMessage } from "@/lib/outbound/send-message";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BodySchema = z.object({
  text: z.string().min(1).max(10_000),
  replyToMessageId: z.string().uuid().optional(),
});

/**
 * POST /api/conversations/:id/messages/send — отправка текста менеджером (§12).
 * Тело содержит ТОЛЬКО text/replyToMessageId. channelId и crmUserId клиент
 * задавать не может — они берутся на backend из диалога и сессии (§24).
 */
export async function POST(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { organizationId, userId } = await getAuthContext();
  const { id } = await params;

  const parsed = BodySchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: "Некорректные данные" }, { status: 400 });
  }

  const result = await createOutboundMessage({
    organizationId,
    conversationId: id,
    userId,
    text: parsed.data.text,
    replyToMessageId: parsed.data.replyToMessageId,
  });

  if (!result.ok) {
    const status = result.code === "not_found" ? 404 : 400;
    return NextResponse.json({ error: result.error }, { status });
  }

  return NextResponse.json(
    { messageId: result.messageId, status: "queued" },
    { status: 202 },
  );
}
