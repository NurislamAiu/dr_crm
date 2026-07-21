import { createHmac, timingSafeEqual } from "node:crypto";
import { getEnv } from "@/lib/env";

/**
 * Публичная подписанная ссылка на содержимое вложения для Wazzup (§14).
 *
 * Wazzup скачивает медиа по contentUri из интернета и НЕ умеет Bearer-авторизацию,
 * а MinIO у нас локальный (недоступен извне). Поэтому отдаём ссылку на наш
 * публичный APP_URL с коротким HMAC-токеном: /content?exp=..&sig=..
 * Подпись покрывает id вложения и срок — так ссылка не даёт доступ к другим файлам
 * и протухает.
 */

function secret(): string {
  const s = getEnv().AUTH_SECRET;
  if (!s) throw new Error("AUTH_SECRET не задан — нельзя подписать ссылку на вложение");
  return s;
}

export function signContentToken(id: string, exp: number): string {
  return createHmac("sha256", secret()).update(`${id}.${exp}`).digest("hex");
}

export function verifyContentToken(id: string, exp: number, sig: string): boolean {
  if (!Number.isFinite(exp) || exp < Math.floor(Date.now() / 1000)) return false;
  const expected = signContentToken(id, exp);
  const a = Buffer.from(sig);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * Публичный URL содержимого вложения для внешних потребителей (Wazzup).
 * ttlSeconds по умолчанию 1 час — Wazzup обычно скачивает сразу, но берём запас
 * на очередь/ретраи.
 */
export function publicContentUri(id: string, ttlSeconds = 3600): string {
  const base = getEnv().APP_URL;
  if (!base) throw new Error("APP_URL не задан — Wazzup не сможет скачать вложение");
  const exp = Math.floor(Date.now() / 1000) + ttlSeconds;
  const sig = signContentToken(id, exp);
  return `${base.replace(/\/$/, "")}/api/attachments/${id}/content?exp=${exp}&sig=${sig}`;
}
