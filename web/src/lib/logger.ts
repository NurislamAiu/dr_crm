/**
 * Минимальный структурный логгер с обязательным маскированием секретов.
 *
 * ТЗ:
 *  - скрывать API-ключ Wazzup в логах;
 *  - маскировать телефоны в системных логах;
 *  - логировать requestId / correlationId при ошибках.
 *
 * На Этапе 8 может быть заменён на pino; интерфейс сохраняем.
 */

type LogLevel = "debug" | "info" | "warn" | "error";

const BEARER_RE = /(Bearer\s+)[A-Za-z0-9._-]+/g;

/** Маскирует телефон: 77011234567 -> 770****4567 (оставляем код и хвост). */
export function maskPhone(phone: string | null | undefined): string {
  if (!phone) return "";
  const digits = phone.replace(/\D/g, "");
  if (digits.length <= 6) return "*".repeat(digits.length);
  const head = digits.slice(0, 3);
  const tail = digits.slice(-4);
  return `${head}${"*".repeat(digits.length - 7)}${tail}`;
}

/** Маскирует секрет (API-ключ / webhook secret): показываем только 4 последних символа. */
export function maskSecret(secret: string | null | undefined): string {
  if (!secret) return "";
  if (secret.length <= 4) return "****";
  return `****${secret.slice(-4)}`;
}

/** Рекурсивно чистит объект от чувствительных полей перед логированием. */
export function redact(value: unknown, seen = new WeakSet<object>()): unknown {
  if (typeof value === "string") {
    return value.replace(BEARER_RE, "$1****");
  }
  if (value === null || typeof value !== "object") return value;
  if (seen.has(value as object)) return "[Circular]";
  seen.add(value as object);

  if (Array.isArray(value)) return value.map((v) => redact(v, seen));

  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value)) {
    const key = k.toLowerCase();
    if (/(apikey|api_key|authorization|secret|password|token)/.test(key)) {
      out[k] = maskSecret(typeof v === "string" ? v : "***");
    } else if (/(phone|chatid|plainid)/.test(key) && typeof v === "string") {
      out[k] = maskPhone(v);
    } else {
      out[k] = redact(v, seen);
    }
  }
  return out;
}

function emit(level: LogLevel, msg: string, meta?: Record<string, unknown>): void {
  const line = {
    ts: new Date().toISOString(),
    level,
    msg,
    ...(meta ? (redact(meta) as Record<string, unknown>) : {}),
  };
  const serialized = JSON.stringify(line);
  if (level === "error") console.error(serialized);
  else if (level === "warn") console.warn(serialized);
  else console.log(serialized);
}

export const logger = {
  debug: (msg: string, meta?: Record<string, unknown>) => emit("debug", msg, meta),
  info: (msg: string, meta?: Record<string, unknown>) => emit("info", msg, meta),
  warn: (msg: string, meta?: Record<string, unknown>) => emit("warn", msg, meta),
  error: (msg: string, meta?: Record<string, unknown>) => emit("error", msg, meta),
};
