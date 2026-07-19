import { getEnv } from "../env.js";
import { WazzupApiClient } from "./client.js";

/**
 * Фабрика серверного клиента Wazzup из валидированного окружения.
 * Единая точка создания — чтобы `channelId`/ключ брались только с backend.
 */
let singleton: WazzupApiClient | null = null;

export function getWazzupClient(): WazzupApiClient {
  if (singleton) return singleton;
  const env = getEnv();
  singleton = new WazzupApiClient({
    baseUrl: env.WAZZUP_API_BASE_URL,
    apiKey: env.WAZZUP_API_KEY,
  });
  return singleton;
}

/** Для тестов: подменить/сбросить синглтон. */
export function __setWazzupClient(client: WazzupApiClient | null): void {
  singleton = client;
}
