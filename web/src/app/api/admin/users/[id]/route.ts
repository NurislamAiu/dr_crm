import { NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/db";
import { getAuthContext, unauthorized, forbidden, isAdmin } from "@/lib/auth/context";
import { hashPassword } from "@/lib/auth/password";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const PatchSchema = z.object({
  name: z.string().min(1).max(120).optional(),
  role: z.enum(["admin", "manager", "viewer"]).optional(),
  isActive: z.boolean().optional(),
  password: z.string().min(6).max(200).optional(),
});

/** PATCH /api/admin/users/:id — изменить менеджера (имя/роль/активность/пароль). */
export async function PATCH(req: Request, { params }: { params: Promise<{ id: string }> }): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!isAdmin(ctx)) return forbidden();
  const { id } = await params;

  const parsed = PatchSchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Некорректные данные" }, { status: 400 });

  const target = await prisma.user.findFirst({
    where: { id, organizationId: ctx.organizationId },
    select: { id: true },
  });
  if (!target) return NextResponse.json({ error: "Менеджер не найден" }, { status: 404 });

  // Себя нельзя деактивировать (чтобы не потерять доступ).
  if (id === ctx.userId && parsed.data.isActive === false) {
    return NextResponse.json({ error: "Нельзя отключить самого себя" }, { status: 400 });
  }

  const data: Record<string, unknown> = {};
  if (parsed.data.name !== undefined) data.name = parsed.data.name;
  if (parsed.data.role !== undefined) data.role = parsed.data.role;
  if (parsed.data.isActive !== undefined) data.isActive = parsed.data.isActive;
  if (parsed.data.password !== undefined) data.passwordHash = hashPassword(parsed.data.password);

  const user = await prisma.user.update({
    where: { id },
    data,
    select: { id: true, email: true, name: true, role: true, isActive: true, createdAt: true },
  });
  return NextResponse.json({ user });
}
