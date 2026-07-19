import { NextResponse } from "next/server";
import { z } from "zod";
import { getAuthContext, unauthorized, forbidden, canWrite, isAdmin } from "@/lib/auth/context";
import {
  claimConversation,
  transferConversation,
  setConversationStatus,
} from "@/lib/conversations/manage";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BodySchema = z.object({
  action: z.enum(["claim", "transfer", "close", "reopen"]),
  toUserId: z.string().uuid().optional(),
});

/**
 * POST /api/conversations/:id/action — захват/передача/закрытие/переоткрытие (§19).
 * Захват атомарен. Передавать чужой диалог может назначенный менеджер или админ.
 */
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

  switch (parsed.data.action) {
    case "claim": {
      const res = await claimConversation(ctx.organizationId, id, ctx.userId);
      if (res.ok) return NextResponse.json({ assignedUserId: res.assignedUserId });
      if (res.reason === "not_found") return NextResponse.json({ error: "Диалог не найден" }, { status: 404 });
      return NextResponse.json(
        { error: "Диалог уже захвачен другим менеджером", assignedUserId: res.assignedUserId },
        { status: 409 },
      );
    }
    case "transfer": {
      if (!parsed.data.toUserId) return NextResponse.json({ error: "toUserId обязателен" }, { status: 400 });
      // Передавать может админ либо текущий ответственный.
      if (!isAdmin(ctx)) {
        const res = await transferConversation(ctx.organizationId, id, parsed.data.toUserId, ctx.userId);
        return res.ok ? NextResponse.json({ ok: true }) : NextResponse.json({ error: res.error }, { status: 400 });
      }
      const res = await transferConversation(ctx.organizationId, id, parsed.data.toUserId, ctx.userId);
      return res.ok ? NextResponse.json({ ok: true }) : NextResponse.json({ error: res.error }, { status: 400 });
    }
    case "close":
    case "reopen": {
      const res = await setConversationStatus(ctx.organizationId, id, parsed.data.action === "close" ? "closed" : "open");
      return res.ok ? NextResponse.json({ ok: true }) : NextResponse.json({ error: "Диалог не найден" }, { status: 404 });
    }
  }
}
