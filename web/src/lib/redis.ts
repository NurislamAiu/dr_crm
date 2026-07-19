import IORedis, { type Redis } from "ioredis";

/**
 * Общее подключение к Redis для BullMQ.
 * maxRetriesPerRequest=null — обязательно для BullMQ blocking-команд.
 */
const globalForRedis = globalThis as unknown as { redis?: Redis };

export function getRedis(): Redis {
  if (globalForRedis.redis) return globalForRedis.redis;
  const url = process.env.REDIS_URL ?? "redis://localhost:6379";
  const connection = new IORedis(url, { maxRetriesPerRequest: null });
  if (process.env.NODE_ENV !== "production") globalForRedis.redis = connection;
  return connection;
}
