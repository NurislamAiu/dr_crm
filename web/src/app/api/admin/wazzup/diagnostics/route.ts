import { NextResponse } from "next/server";
import { prisma } from "@/lib/db";
import { getRedis } from "@/lib/redis";
import { getAuthContext, unauthorized, forbidden, isAdmin } from "@/lib/auth/context";
import { getWazzupClient } from "@/lib/wazzup/factory";
import { collectWazzupDiagnostics } from "@/lib/wazzup/diagnostics";
import { getWebhookQueue } from "@/lib/queue/webhook-queue";
import { getSendQueue } from "@/lib/queue/send-queue";
import { getMediaQueue } from "@/lib/queue/media-queue";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /api/admin/wazzup/diagnostics — страница «Настройки → Wazzup → Диагностика»
 * (ТЗ §25). Только для админа. Собирает состояние Wazzup + инфраструктуры.
 */
export async function GET(req: Request): Promise<Response> {
  const ctx = getAuthContext(req);
  if (!ctx) return unauthorized();
  if (!isAdmin(ctx)) return forbidden();

  const wazzup = await collectWazzupDiagnostics(getWazzupClient());

  const [redis, postgres] = await Promise.all([
    getRedis().ping().then((p) => p === "PONG").catch(() => false),
    prisma.$queryRaw`SELECT 1`.then(() => true).catch(() => false),
  ]);

  const since = new Date(Date.now() - 24 * 3600 * 1000);
  const [messages24h, failedWebhooks, webhookCounts, sendCounts, mediaCounts] = await Promise.all([
    prisma.message.count({ where: { organizationId: ctx.organizationId, createdAt: { gte: since } } }),
    prisma.wazzupWebhookEvent.count({ where: { organizationId: ctx.organizationId, status: "failed" } }),
    getWebhookQueue().getJobCounts("waiting", "active", "failed"),
    getSendQueue().getJobCounts("waiting", "active", "failed"),
    getMediaQueue().getJobCounts("waiting", "active", "failed"),
  ]);

  const lastWebhook = await prisma.wazzupWebhookEvent.findFirst({
    where: { organizationId: ctx.organizationId },
    orderBy: { receivedAt: "desc" },
    select: { receivedAt: true, status: true, isTest: true },
  });

  return NextResponse.json({
    wazzup,
    infra: {
      redis: redis ? "ok" : "down",
      postgres: postgres ? "ok" : "down",
      queues: { webhook: webhookCounts, send: sendCounts, media: mediaCounts },
    },
    stats: {
      messagesLast24h: messages24h,
      failedWebhookEvents: failedWebhooks,
      lastWebhookAt: lastWebhook?.receivedAt ?? null,
      lastWebhookStatus: lastWebhook?.status ?? null,
    },
  });
}
