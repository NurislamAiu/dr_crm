import { NextResponse } from "next/server";
import { z } from "zod";
import { getAuthContext, unauthorized, forbidden, canWrite } from "@/lib/auth/context";
import { sendBroadcastMessage } from "@/lib/outbound/broadcast";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BodySchema = z.object({
  name: z.string().max(200).optional().default(""),
  phone: z.string().min(3).max(40),
  text: z.string().min(1).max(4000),
});

/**
 * POST /api/broadcast/send — отправка ОДНОГО сообщения рассылки (сервисные
 * напоминания пациентам). Пауза между контактами — на клиенте (20 c).
 */
export async function POST(req: Request): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!canWrite(ctx)) return forbidden();

  const parsed = BodySchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ ok: false, error: "Некорректные данные" }, { status: 400 });
  }

  const result = await sendBroadcastMessage({
    organizationId: ctx.organizationId,
    userId: ctx.userId,
    name: parsed.data.name,
    phone: parsed.data.phone,
    text: parsed.data.text,
  });

  return NextResponse.json(result, { status: result.ok ? 200 : 200 });
}
