import { Worker } from "bullmq";
import { getRedis } from "@/lib/redis";
import { logger } from "@/lib/logger";
import { WEBHOOK_QUEUE_NAME, type WebhookJobData } from "@/lib/queue/webhook-queue";
import { SEND_QUEUE_NAME, type SendJobData } from "@/lib/queue/send-queue";
import { MEDIA_QUEUE_NAME, type MediaJobData } from "@/lib/queue/media-queue";
import { processWebhookEvent } from "./process-webhook-event";
import { processSend } from "./process-send";
import { downloadAndStoreAttachment } from "@/lib/media/download";

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

const sendWorker = new Worker<SendJobData>(
  SEND_QUEUE_NAME,
  async (job) => {
    const outcome = await processSend(job.data.messageId);
    logger.info("send-worker: отправка обработана", { messageId: job.data.messageId, outcome });
    return outcome;
  },
  { connection: getRedis(), concurrency: 5 },
);

const mediaWorker = new Worker<MediaJobData>(
  MEDIA_QUEUE_NAME,
  async (job) => {
    const outcome = await downloadAndStoreAttachment(job.data.attachmentId);
    logger.info("media-worker: скачивание обработано", { attachmentId: job.data.attachmentId, outcome });
    return outcome;
  },
  { connection: getRedis(), concurrency: 4 },
);

worker.on("failed", (job, err) => {
  logger.error("worker: джоба провалилась", { jobId: job?.id, attempts: job?.attemptsMade, error: err.message });
});
sendWorker.on("failed", (job, err) => {
  logger.error("send-worker: джоба провалилась", { jobId: job?.id, attempts: job?.attemptsMade, error: err.message });
});
mediaWorker.on("failed", (job, err) => {
  logger.error("media-worker: джоба провалилась", { jobId: job?.id, attempts: job?.attemptsMade, error: err.message });
});

worker.on("ready", () => logger.info("worker: готов, слушаю очередь", { queue: WEBHOOK_QUEUE_NAME }));
sendWorker.on("ready", () => logger.info("send-worker: готов, слушаю очередь", { queue: SEND_QUEUE_NAME }));
mediaWorker.on("ready", () => logger.info("media-worker: готов, слушаю очередь", { queue: MEDIA_QUEUE_NAME }));

async function shutdown(signal: string): Promise<void> {
  logger.info("worker: остановка", { signal });
  await Promise.all([worker.close(), sendWorker.close(), mediaWorker.close()]);
  process.exit(0);
}
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));
