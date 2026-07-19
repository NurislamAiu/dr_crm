import { NextResponse } from "next/server";
import { z } from "zod";
import { getAuthContext, unauthorized, forbidden, canWrite } from "@/lib/auth/context";
import { editOutboundMessage, deleteOutboundMessage } from "@/lib/outbound/edit-delete";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const EditSchema = z.object({ text: z.string().min(1).max(10_000) });

/** PATCH /api/messages/:id — изменить текст своего отправленного сообщения (§16). */
export async function PATCH(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!canWrite(ctx)) return forbidden();
  const { id } = await params;

  const parsed = EditSchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Некорректные данные" }, { status: 400 });

  const res = await editOutboundMessage(ctx.organizationId, id, ctx.userId, parsed.data.text);
  return res.ok ? NextResponse.json({ ok: true }) : NextResponse.json({ error: res.error }, { status: 400 });
}

/** DELETE /api/messages/:id — удалить своё отправленное сообщение (§16). */
export async function DELETE(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!canWrite(ctx)) return forbidden();
  const { id } = await params;

  const res = await deleteOutboundMessage(ctx.organizationId, id);
  return res.ok ? NextResponse.json({ ok: true }) : NextResponse.json({ error: res.error }, { status: 400 });
}
