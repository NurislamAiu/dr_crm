import { NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { getRedis } from "@/lib/redis";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Health check (ТЗ инфра): проверяем PostgreSQL и Redis. */
export async function GET(): Promise<Response> {
  const checks: Record<string, "ok" | "down"> = { postgres: "down", redis: "down" };

  try {
    await prisma.$queryRaw`SELECT 1`;
    checks.postgres = "ok";
  } catch {
    /* down */
  }
  try {
    const pong = await getRedis().ping();
    checks.redis = pong === "PONG" ? "ok" : "down";
  } catch {
    /* down */
  }

  const healthy = Object.values(checks).every((v) => v === "ok");
  return NextResponse.json(
    { status: healthy ? "ok" : "degraded", checks },
    { status: healthy ? 200 : 503 },
  );
}
