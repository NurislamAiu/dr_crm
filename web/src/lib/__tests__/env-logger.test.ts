import { test } from "node:test";
import assert from "node:assert/strict";
import { getEnv, resetEnvCache, EnvValidationError } from "../env.js";
import { maskPhone, maskSecret, redact } from "../logger.js";

const baseEnv = {
  WAZZUP_API_KEY: "abcd1234",
  WAZZUP_WEBHOOK_SECRET: "whsecret",
};

test("getEnv: валидирует и подставляет дефолты", () => {
  resetEnvCache();
  const env = getEnv({ ...baseEnv });
  assert.equal(env.WAZZUP_API_BASE_URL, "https://api.wazzup24.com");
  assert.equal(env.WAZZUP_EXPECTED_TRANSPORT, "whatsapp");
});

test("getEnv: убирает хвостовой слэш у base url", () => {
  resetEnvCache();
  const env = getEnv({ ...baseEnv, WAZZUP_API_BASE_URL: "https://api.wazzup24.com/" });
  assert.equal(env.WAZZUP_API_BASE_URL, "https://api.wazzup24.com");
});

test("getEnv: запрещает NEXT_PUBLIC ключ Wazzup", () => {
  resetEnvCache();
  assert.throws(
    () => getEnv({ ...baseEnv, NEXT_PUBLIC_WAZZUP_API_KEY: "leak" }),
    (err: unknown) => err instanceof EnvValidationError,
  );
});

test("getEnv: без обязательных полей — ошибка", () => {
  resetEnvCache();
  assert.throws(() => getEnv({}), (err: unknown) => err instanceof EnvValidationError);
});

test("maskPhone: маскирует середину", () => {
  assert.equal(maskPhone("77011234567"), "770****4567");
  assert.equal(maskPhone("12345"), "*****");
});

test("maskSecret: показывает только хвост", () => {
  assert.equal(maskSecret("abcd1234"), "****1234");
  assert.equal(maskSecret("xyz"), "****");
});

test("redact: чистит authorization, apiKey, phone", () => {
  const cleaned = redact({
    Authorization: "Bearer supersecrettoken",
    apiKey: "abcd1234",
    phone: "77011234567",
    nested: { chatId: "77019998877", text: "ok" },
  }) as Record<string, unknown>;
  assert.equal(cleaned.apiKey, "****1234");
  assert.match(String(cleaned.Authorization), /\*\*\*\*/);
  assert.equal(cleaned.phone, "770****4567");
  const nested = cleaned.nested as Record<string, unknown>;
  assert.equal(nested.chatId, "770****8877");
  assert.equal(nested.text, "ok");
});
