import { z } from "zod";

/**
 * Валидация переменных окружения через Zod.
 *
 * Требования ТЗ:
 *  - WAZZUP_API_KEY — секрет, только backend;
 *  - NEXT_PUBLIC_WAZZUP_API_KEY создавать ЗАПРЕЩЕНО (проверяем это явно).
 *
 * Валидация ленивая: `getEnv()` вычисляется и кэшируется при первом вызове,
 * чтобы импорт модулей (в т.ч. в юнит-тестах) не требовал заполненного .env.
 */

const serverEnvSchema = z.object({
  // --- Wazzup ---
  WAZZUP_API_BASE_URL: z
    .string()
    .url()
    .default("https://api.wazzup24.com")
    // нормализуем: убираем хвостовой слэш, чтобы не получить `//v3`
    .transform((v) => v.replace(/\/+$/, "")),
  WAZZUP_API_KEY: z.string().min(1, "WAZZUP_API_KEY обязателен"),
  WAZZUP_WEBHOOK_SECRET: z.string().min(1, "WAZZUP_WEBHOOK_SECRET обязателен"),
  WAZZUP_CHANNEL_ID: z.string().uuid("WAZZUP_CHANNEL_ID должен быть UUID канала").optional(),
  WAZZUP_EXPECTED_TRANSPORT: z.string().default("whatsapp"),

  // --- Инфраструктура ---
  DATABASE_URL: z.string().min(1).optional(),
  REDIS_URL: z.string().min(1).optional(),
  APP_URL: z.string().url().optional(),
  AUTH_SECRET: z.string().min(1).optional(),

  // --- S3 / MinIO ---
  STORAGE_ENDPOINT: z.string().url().optional(),
  STORAGE_BUCKET: z.string().min(1).optional(),
  STORAGE_ACCESS_KEY: z.string().min(1).optional(),
  STORAGE_SECRET_KEY: z.string().min(1).optional(),
});

export type ServerEnv = z.infer<typeof serverEnvSchema>;

let cached: ServerEnv | null = null;

/** Ошибка конфигурации окружения — отделяем от рантайм-ошибок Wazzup. */
export class EnvValidationError extends Error {
  constructor(
    message: string,
    readonly issues: readonly string[],
  ) {
    super(message);
    this.name = "EnvValidationError";
  }
}

function assertNoPublicApiKey(source: Record<string, string | undefined>): void {
  // Жёсткий запрет ТЗ: ключ Wazzup не должен утечь во frontend.
  const leaked = Object.keys(source).filter(
    (k) => k.startsWith("NEXT_PUBLIC_") && /WAZZUP.*KEY|API_KEY/i.test(k),
  );
  if (leaked.length > 0) {
    throw new EnvValidationError(
      `Обнаружены публичные переменные с ключом Wazzup: ${leaked.join(", ")}. ` +
        `API-ключ Wazzup запрещено экспортировать во frontend.`,
      leaked,
    );
  }
}

export function getEnv(source: Record<string, string | undefined> = process.env): ServerEnv {
  if (cached) return cached;

  assertNoPublicApiKey(source);

  const parsed = serverEnvSchema.safeParse(source);
  if (!parsed.success) {
    const issues = parsed.error.issues.map(
      (i) => `${i.path.join(".") || "(root)"}: ${i.message}`,
    );
    throw new EnvValidationError(
      `Некорректное окружение:\n  - ${issues.join("\n  - ")}`,
      issues,
    );
  }

  cached = parsed.data;
  return cached;
}

/** Только для тестов: сбросить кэш. */
export function resetEnvCache(): void {
  cached = null;
}
