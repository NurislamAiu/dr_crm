import { Queue } from "bullmq";
import { getRedis } from "@/lib/redis";

export const WEBHOOK_QUEUE_NAME = "wazzup-webhook";

export interface WebhookJobData {
  /** id записи WazzupWebhookEvent. */
  eventId: string;
}

const globalForQueue = globalThis as unknown as { webhookQueue?: Queue<WebhookJobData> };

export function getWebhookQueue(): Queue<WebhookJobData> {
  if (globalForQueue.webhookQueue) return globalForQueue.webhookQueue;
  const queue = new Queue<WebhookJobData>(WEBHOOK_QUEUE_NAME, {
    connection: getRedis(),
    defaultJobOptions: {
      attempts: 5,
      backoff: { type: "exponential", delay: 2000 },
      removeOnComplete: { age: 3600, count: 1000 },
      removeOnFail: { age: 24 * 3600 },
    },
  });
  if (process.env.NODE_ENV !== "production") globalForQueue.webhookQueue = queue;
  return queue;
}

/**
 * Поставить обработку webhook-события в очередь.
 * jobId = eventId → повторный enqueue того же события не создаёт дубль джобы.
 */
export async function enqueueWebhookEvent(eventId: string): Promise<void> {
  await getWebhookQueue().add("process", { eventId }, { jobId: eventId });
}
