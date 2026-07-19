import { Queue } from "bullmq";
import { getRedis } from "@/lib/redis";

export const SEND_QUEUE_NAME = "wazzup-send";

export interface SendJobData {
  /** id локального Message (status=queued). */
  messageId: string;
}

const globalForQueue = globalThis as unknown as { sendQueue?: Queue<SendJobData> };

export function getSendQueue(): Queue<SendJobData> {
  if (globalForQueue.sendQueue) return globalForQueue.sendQueue;
  const queue = new Queue<SendJobData>(SEND_QUEUE_NAME, {
    connection: getRedis(),
    defaultJobOptions: {
      attempts: 4,
      backoff: { type: "exponential", delay: 2000 },
      removeOnComplete: { age: 3600, count: 1000 },
      removeOnFail: { age: 24 * 3600 },
    },
  });
  if (process.env.NODE_ENV !== "production") globalForQueue.sendQueue = queue;
  return queue;
}

/**
 * Поставить отправку в очередь. jobId НЕ фиксируем: повтор («Повторить»)
 * должен переобработать сообщение, а прошлая completed-джоба с тем же jobId
 * заблокировала бы это. Защита от двойной отправки — на уровне БД (проверка
 * status/externalMessageId в processSend) и crmMessageId в Wazzup (§13).
 */
export async function enqueueSend(messageId: string): Promise<void> {
  await getSendQueue().add("send", { messageId });
}
