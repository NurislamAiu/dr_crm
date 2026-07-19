import { Worker } from "bullmq";
import { getRedis } from "@/lib/redis";
import { logger } from "@/lib/logger";
import { WEBHOOK_QUEUE_NAME, type WebhookJobData } from "@/lib/queue/webhook-queue";
import { processWebhookEvent } from "./process-webhook-event";

/**
 * Отдельный процесс-воркер BullMQ (ТЗ §1: тяжёлая работа вне HTTP-запроса).
 * Запуск: `npm run worker` (prod) / `npm run worker:dev` (watch).
 */
const worker = new Worker<WebhookJobData>(
  WEBHOOK_QUEUE_NAME,
  async (job) => {
    const { eventId } = job.data;
    const result = await processWebhookEvent(eventId);
    logger.info("worker: webhook обработан", { eventId, ...result });
    return result;
  },
  { connection: getRedis(), concurrency: 5 },
);

worker.on("failed", (job, err) => {
  logger.error("worker: джоба провалилась", {
    jobId: job?.id,
    attempts: job?.attemptsMade,
    error: err.message,
  });
});

worker.on("ready", () => logger.info("worker: готов, слушаю очередь", { queue: WEBHOOK_QUEUE_NAME }));

async function shutdown(signal: string): Promise<void> {
  logger.info("worker: остановка", { signal });
  await worker.close();
  process.exit(0);
}
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));
