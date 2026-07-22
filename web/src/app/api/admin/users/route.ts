import { NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/db";
import { getAuthContext, unauthorized, forbidden, isAdmin } from "@/lib/auth/context";
import { hashPassword } from "@/lib/auth/password";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** GET /api/admin/users — список менеджеров организации (только админ). */
export async function GET(req: Request): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!isAdmin(ctx)) return forbidden();

  const users = await prisma.user.findMany({
    where: { organizationId: ctx.organizationId },
    select: { id: true, email: true, name: true, role: true, isActive: true, createdAt: true },
    orderBy: { createdAt: "asc" },
  });
  return NextResponse.json({ users });
}

const CreateSchema = z.object({
  email: z.string().email(),
  name: z.string().min(1).max(120),
  password: z.string().min(6).max(200),
  role: z.enum(["admin", "manager", "viewer"]).default("manager"),
});

/** POST /api/admin/users — создать менеджера (только админ). */
export async function POST(req: Request): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!isAdmin(ctx)) return forbidden();

  const parsed = CreateSchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) {
    return NextResponse.json({ error: "Проверьте email, имя и пароль (от 6 символов)" }, { status: 400 });
  }
  const { email, name, password, role } = parsed.data;

  const exists = await prisma.user.findFirst({
    where: { organizationId: ctx.organizationId, email },
    select: { id: true },
  });
  if (exists) return NextResponse.json({ error: "Менеджер с таким email уже есть" }, { status: 409 });

  const user = await prisma.user.create({
    data: {
      organizationId: ctx.organizationId,
      email,
      name,
      role,
      passwordHash: hashPassword(password),
    },
    select: { id: true, email: true, name: true, role: true, isActive: true, createdAt: true },
  });
  return NextResponse.json({ user }, { status: 201 });
}
