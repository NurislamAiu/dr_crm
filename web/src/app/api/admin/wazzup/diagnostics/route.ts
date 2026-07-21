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
  const [messages24h, failedWebhooks, webhookEvents24h, webhookCounts, sendCounts, mediaCounts] = await Promise.all([
    prisma.message.count({ where: { organizationId: ctx.organizationId, createdAt: { gte: since } } }),
    prisma.wazzupWebhookEvent.count({ where: { organizationId: ctx.organizationId, status: "failed" } }),
    prisma.wazzupWebhookEvent.count({ where: { organizationId: ctx.organizationId, receivedAt: { gte: since } } }),
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
    receiveDiagnosis: diagnoseReceive(wazzup, webhookEvents24h),
    wazzup,
    infra: {
      redis: redis ? "ok" : "down",
      postgres: postgres ? "ok" : "down",
      queues: { webhook: webhookCounts, send: sendCounts, media: mediaCounts },
    },
    stats: {
      messagesLast24h: messages24h,
      failedWebhookEvents: failedWebhooks,
      webhookEventsLast24h: webhookEvents24h,
      lastWebhookAt: lastWebhook?.receivedAt ?? null,
      lastWebhookStatus: lastWebhook?.status ?? null,
    },
  });
}

/**
 * Вердикт «почему входящие могут не доходить» (сценарий: отправка работает,
 * приём — нет). Собирает конкретные причины из состояния Wazzup-webhook и
 * факта прихода событий за 24ч, чтобы админ сразу видел, что чинить.
 */
function diagnoseReceive(
  wazzup: Awaited<ReturnType<typeof collectWazzupDiagnostics>>,
  webhookEvents24h: number,
): { canReceive: boolean; reasons: string[] } {
  const reasons: string[] = [];
  const wh = wazzup.webhook;

  if (!wazzup.connection.ok) {
    reasons.push("Нет связи с Wazzup API — проверьте WAZZUP_API_KEY и сеть.");
  }
  if (!wh.configured) {
    reasons.push(
      "Webhook в Wazzup не настроен (webhooksUri пуст). Нажмите «Настроить webhook».",
    );
  }
  if (wh.appUrl == null) {
    reasons.push("APP_URL не задан в .env — некуда регистрировать webhook.");
  } else if (/localhost|127\.0\.0\.1/i.test(wh.appUrl)) {
    reasons.push(
      `APP_URL=${wh.appUrl} — локальный адрес, из интернета Wazzup его не видит. Нужен публичный домен/туннель.`,
    );
  }
  if (wh.configured && wh.matchesAppUrl === false) {
    reasons.push(
      `Адрес в Wazzup (${wh.webhooksUri ?? "—"}) не совпадает с текущим APP_URL. ` +
        "Скорее всего сменился адрес туннеля — перезапустите dev и нажмите «Настроить webhook».",
    );
  }
  if (wh.configured && wh.messagesAndStatuses === false) {
    reasons.push("Подписка messagesAndStatuses выключена — входящие сообщения не шлются.");
  }
  if (reasons.length === 0 && webhookEvents24h === 0) {
    reasons.push(
      "Конфигурация выглядит верной, но за 24ч не пришло ни одного webhook. " +
        "Проверьте, что туннель запущен и доступен снаружи (curl по публичному URL с ?secret=).",
    );
  }

  return { canReceive: reasons.length === 0, reasons };
}
