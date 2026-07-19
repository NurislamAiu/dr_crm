import { Queue } from "bullmq";
import { getRedis } from "@/lib/redis";

export const MEDIA_QUEUE_NAME = "wazzup-media";

export interface MediaJobData {
  attachmentId: string;
}

const globalForQueue = globalThis as unknown as { mediaQueue?: Queue<MediaJobData> };

export function getMediaQueue(): Queue<MediaJobData> {
  if (globalForQueue.mediaQueue) return globalForQueue.mediaQueue;
  const queue = new Queue<MediaJobData>(MEDIA_QUEUE_NAME, {
    connection: getRedis(),
    defaultJobOptions: {
      attempts: 4,
      backoff: { type: "exponential", delay: 3000 },
      removeOnComplete: { age: 3600, count: 1000 },
      removeOnFail: { age: 24 * 3600 },
    },
  });
  if (process.env.NODE_ENV !== "production") globalForQueue.mediaQueue = queue;
  return queue;
}

/** jobId по attachmentId — не качаем один и тот же файл дважды. */
export async function enqueueMediaDownload(attachmentId: string): Promise<void> {
  await getMediaQueue().add("download", { attachmentId }, { jobId: attachmentId });
}
