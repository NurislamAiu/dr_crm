import { NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/db";
import { getAuthContext, unauthorized, forbidden, canWrite } from "@/lib/auth/context";
import { addInternalNote } from "@/lib/conversations/manage";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BodySchema = z.object({ text: z.string().min(1).max(5000) });

/** GET — список внутренних заметок диалога (§19). */
export async function GET(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  const { id } = await params;

  const conv = await prisma.conversation.findFirst({
    where: { id, organizationId: ctx.organizationId },
    select: { id: true },
  });
  if (!conv) return NextResponse.json({ error: "not found" }, { status: 404 });

  const notes = await prisma.internalNote.findMany({
    where: { conversationId: id },
    orderBy: { createdAt: "asc" },
    select: { id: true, text: true, createdAt: true, author: { select: { id: true, name: true } } },
  });
  return NextResponse.json({ notes });
}

/** POST — добавить внутреннюю заметку. НИКОГДА не уходит в Wazzup. */
export async function POST(
  req: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!canWrite(ctx)) return forbidden();
  const { id } = await params;

  const parsed = BodySchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Некорректные данные" }, { status: 400 });

  const res = await addInternalNote(ctx.organizationId, id, ctx.userId, parsed.data.text);
  if (!res.ok) return NextResponse.json({ error: res.error }, { status: 404 });
  return NextResponse.json({ noteId: res.noteId }, { status: 201 });
}
