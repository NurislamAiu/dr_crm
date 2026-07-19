import { NextResponse, type NextRequest } from "next/server";

/**
 * Security-заголовки для всех ответов + базовый rate-limit на /api/auth/login
 * (защита от перебора, §24). Для прод-масштаба лимит лучше вынести в Redis;
 * здесь — простой per-instance счётчик.
 */

const WINDOW_MS = 60_000;
const MAX_LOGIN_ATTEMPTS = 10;
const hits = new Map<string, { count: number; resetAt: number }>();

function rateLimited(ip: string): boolean {
  const now = Date.now();
  const entry = hits.get(ip);
  if (!entry || entry.resetAt < now) {
    hits.set(ip, { count: 1, resetAt: now + WINDOW_MS });
    return false;
  }
  entry.count += 1;
  return entry.count > MAX_LOGIN_ATTEMPTS;
}

function securityHeaders(res: NextResponse): NextResponse {
  res.headers.set("X-Content-Type-Options", "nosniff");
  res.headers.set("X-Frame-Options", "DENY");
  res.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  res.headers.set("X-DNS-Prefetch-Control", "off");
  res.headers.set("Permissions-Policy", "geolocation=(), microphone=(), camera=()");
  return res;
}

export function middleware(req: NextRequest): NextResponse {
  if (req.nextUrl.pathname === "/api/auth/login" && req.method === "POST") {
    const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
    if (rateLimited(ip)) {
      return securityHeaders(
        NextResponse.json({ error: "Слишком много попыток входа. Повторите позже." }, { status: 429 }),
      );
    }
  }
  return securityHeaders(NextResponse.next());
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
