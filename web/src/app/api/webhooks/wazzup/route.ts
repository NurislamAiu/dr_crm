import { NextResponse } from "next/server";
import { getEnv } from "@/lib/env";
import { prisma } from "@/lib/db";
import { logger } from "@/lib/logger";
import { enqueueWebhookEvent } from "@/lib/queue/webhook-queue";
import { sha256, verifyWebhookSecret } from "@/lib/wazzup/webhook-auth";

// node-рантайм: нужны node:crypto, prisma, bullmq (не edge).
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 2 * 1024 * 1024; // 2 MB (ТЗ §6 п.6)
const ORG_ID = process.env.DEFAULT_ORG_ID ?? "default";

export async function POST(req: Request): Promise<Response> {
  const env = getEnv();

  // 1. Ограничение размера тела.
  const raw = await req.text();
  if (Buffer.byteLength(raw, "utf8") > MAX_BODY_BYTES) {
    logger.warn("webhook: тело превышает лимит");
    return NextResponse.json({ error: "payload too large" }, { status: 413 });
  }

  // 2. Разбор JSON.
  let payload: unknown;
  try {
    payload = raw ? JSON.parse(raw) : {};
  } catch {
    return NextResponse.json({ error: "invalid json" }, { status: 400 });
  }

  // 3. Проверка секрета (заголовок Bearer или ?secret= в URL).
  const url = new URL(req.url);
  const authorized = verifyWebhookSecret({
    expectedSecret: env.WAZZUP_WEBHOOK_SECRET,
    authorizationHeader: req.headers.get("authorization"),
    urlSecret: url.searchParams.get("secret"),
  });
  if (!authorized) {
    logger.warn("webhook: неверный секрет");
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const isTest =
    typeof payload === "object" &&
    payload !== null &&
    (payload as { test?: unknown }).test === true;

  const digest = sha256(raw || "{}");

  // 4. Сохранить raw + sha256, создать событие (идемпотентно по sha256).
  //    Тяжёлую работу НЕ делаем в HTTP-запросе — только enqueue.
  try {
    const existing = await prisma.wazzupWebhookEvent.findUnique({
      where: { organizationId_payloadSha256: { organizationId: ORG_ID, payloadSha256: digest } },
      select: { id: true },
    });

    if (existing) {
      // Повторный идентичный webhook — уже принят. Возвращаем 200, не дублируем.
      logger.info("webhook: дубликат (sha256 совпал), пропуск", { eventId: existing.id });
      return NextResponse.json({ ok: true, duplicate: true }, { status: 200 });
    }

    const p = payload as {
      messages?: unknown[];
      statuses?: unknown[];
      channelsUpdates?: unknown[];
    };
    const event = await prisma.wazzupWebhookEvent.create({
      data: {
        organizationId: ORG_ID,
        payloadSha256: digest,
        rawPayload: payload as object,
        isTest,
        messageCount: Array.isArray(p.messages) ? p.messages.length : 0,
        statusCount: Array.isArray(p.statuses) ? p.statuses.length : 0,
        channelUpdateCount: Array.isArray(p.channelsUpdates) ? p.channelsUpdates.length : 0,
      },
      select: { id: true },
    });

    // Тестовый пинг: сохранили для диагностики, тяжёлую обработку не ставим.
    if (!isTest) {
      await enqueueWebhookEvent(event.id);
    } else {
      await prisma.wazzupWebhookEvent.update({
        where: { id: event.id },
        data: { status: "processed", processedAt: new Date() },
      });
    }

    // 5. Немедленный 200.
    return NextResponse.json({ ok: true }, { status: 200 });
  } catch (err) {
    // Даже при сбое БД не теряем факт webhook — логируем полный payload-хэш.
    logger.error("webhook: ошибка приёма", {
      error: err instanceof Error ? err.message : String(err),
      sha256: digest,
    });
    // Возвращаем 500, чтобы Wazzup повторил доставку (raw не потерян на их стороне).
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}
