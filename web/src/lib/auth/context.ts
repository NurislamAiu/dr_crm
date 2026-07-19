import { NextResponse } from "next/server";
import { getEnv } from "@/lib/env";
import { verifyJwt } from "./jwt";

/**
 * Контекст авторизации из JWT (Bearer). Заменил DEV-заголовок x-user-id (§24).
 * organizationId и роль берутся из подписанного токена, не из запроса клиента.
 */
export interface AuthContext {
  organizationId: string;
  userId: string;
  role: string;
  name: string | null;
}

/** Достаёт и проверяет Bearer-JWT. null — если токена нет или он невалиден. */
export function getAuthContext(req: Request): AuthContext | null {
  const header = req.headers.get("authorization");
  const m = header ? /^Bearer\s+(.+)$/i.exec(header.trim()) : null;
  const token = m?.[1]?.trim();
  if (!token) return null;

  const secret = getEnv().AUTH_SECRET;
  if (!secret) return null;
  const payload = verifyJwt(token, secret);
  if (!payload) return null;

  return { organizationId: payload.org, userId: payload.sub, role: payload.role, name: payload.name ?? null };
}

/** 401-ответ для неаутентифицированных. */
export function unauthorized(): Response {
  return NextResponse.json({ error: "Требуется авторизация" }, { status: 401 });
}

/** 403-ответ для недостатка прав. */
export function forbidden(): Response {
  return NextResponse.json({ error: "Недостаточно прав" }, { status: 403 });
}

// --- RBAC (§24) ---
export function canWrite(ctx: AuthContext): boolean {
  return ctx.role === "admin" || ctx.role === "manager";
}
export function isAdmin(ctx: AuthContext): boolean {
  return ctx.role === "admin";
}
