import { NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/db";
import { getEnv } from "@/lib/env";
import { verifyPassword } from "@/lib/auth/password";
import { signJwt } from "@/lib/auth/jwt";
import { logger } from "@/lib/logger";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const BodySchema = z.object({ email: z.string().email(), password: z.string().min(1) });

/**
 * POST /api/auth/login — вход менеджера, возвращает JWT (§7 auth).
 * Токен несёт org/role — клиент не может их подменить (§24).
 */
export async function POST(req: Request): Promise<Response> {
  const parsed = BodySchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Некорректные данные" }, { status: 400 });

  const user = await prisma.user.findFirst({
    where: { email: parsed.data.email, isActive: true },
    select: { id: true, organizationId: true, name: true, role: true, passwordHash: true },
  });

  // Одинаковый ответ для «нет пользователя» и «неверный пароль» — не раскрываем.
  if (!user || !verifyPassword(parsed.data.password, user.passwordHash)) {
    logger.warn("login: неудачная попытка", { email: parsed.data.email });
    return NextResponse.json({ error: "Неверный email или пароль" }, { status: 401 });
  }

  const token = signJwt(
    { sub: user.id, org: user.organizationId, role: user.role, name: user.name },
    getEnv().AUTH_SECRET!,
  );

  return NextResponse.json({
    token,
    user: { id: user.id, name: user.name, role: user.role, organizationId: user.organizationId },
  });
}
