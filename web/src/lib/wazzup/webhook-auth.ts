import { createHash, timingSafeEqual } from "node:crypto";

/**
 * Проверка секрета входящего webhook (ТЗ §6 п.4–5).
 * Wazzup при заданном crmKey шлёт `Authorization: Bearer <crmKey>`.
 * Дополнительно поддерживаем `?secret=` в URL (наш webhooksUri несёт секрет).
 *
 * Сравнение — constant-time, чтобы не давать timing-подсказок.
 */

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

export function verifyWebhookSecret(params: {
  expectedSecret: string;
  authorizationHeader: string | null;
  urlSecret: string | null;
}): boolean {
  const { expectedSecret, authorizationHeader, urlSecret } = params;
  if (!expectedSecret) return false;

  if (urlSecret && safeEqual(urlSecret, expectedSecret)) return true;

  if (authorizationHeader) {
    const m = /^Bearer\s+(.+)$/i.exec(authorizationHeader.trim());
    const token = m?.[1]?.trim();
    if (token && safeEqual(token, expectedSecret)) return true;
  }
  return false;
}

/** SHA-256 сырого тела webhook — для идемпотентности приёма (ТЗ §6 п.8). */
export function sha256(raw: string): string {
  return createHash("sha256").update(raw, "utf8").digest("hex");
}
