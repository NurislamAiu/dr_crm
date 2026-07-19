import { getEnv } from "../env";
import type { WazzupApiClient } from "./client";
import { evaluateChannelState, findWhatsappChannel } from "./channel-state";
import type { Channel } from "./schemas";

/**
 * Сервис диагностики Wazzup (ТЗ §25). На Этапе 1 покрывает то, что зависит
 * только от Wazzup API (ключ, канал, webhook). Проверки Redis/PostgreSQL/
 * очередей/24ч-статистики добавляются на Этапах 2–5 (поля зарезервированы).
 */

export interface WazzupDiagnostics {
  apiKeyConfigured: boolean;
  connection: { ok: boolean; error?: string; httpStatus?: number };
  channel: {
    found: boolean;
    channelId?: string;
    transport?: string;
    plainId?: string;
    state?: string;
    canSend: boolean;
    adminMessage: string | null;
    expectedTransportMatches: boolean;
  };
  webhook: {
    configured: boolean;
    webhooksUri?: string | null;
    subscriptions?: Record<string, unknown>;
    error?: string;
  };
  checkedAt: string;
  // Зарезервировано для последующих этапов:
  redis?: { ok: boolean } | undefined;
  postgres?: { ok: boolean } | undefined;
  queue?: { waiting: number; failed: number } | undefined;
  messagesLast24h?: number | undefined;
}

export async function collectWazzupDiagnostics(
  client: WazzupApiClient,
  correlationId?: string,
): Promise<WazzupDiagnostics> {
  const env = getEnv();
  const checkedAt = new Date().toISOString();
  const apiKeyConfigured = env.WAZZUP_API_KEY.length > 0;

  const conn = await client.testConnection(correlationId);

  const result: WazzupDiagnostics = {
    apiKeyConfigured,
    connection: conn.ok
      ? { ok: true }
      : { ok: false, error: conn.error, ...(conn.httpStatus ? { httpStatus: conn.httpStatus } : {}) },
    channel: {
      found: false,
      canSend: false,
      adminMessage: null,
      expectedTransportMatches: false,
    },
    webhook: { configured: false },
    checkedAt,
  };

  if (!conn.ok) return result;

  const channels: Channel[] = conn.channels;
  const target = findWhatsappChannel(channels, {
    expectedChannelId: env.WAZZUP_CHANNEL_ID,
  });

  if (target) {
    const status = evaluateChannelState(target.state);
    result.channel = {
      found: true,
      channelId: target.channelId,
      transport: target.transport,
      plainId: target.plainId,
      state: target.state,
      canSend: status.canSend,
      adminMessage: status.adminMessage,
      expectedTransportMatches: target.transport === env.WAZZUP_EXPECTED_TRANSPORT,
    };
  }

  // Webhook — отдельный вызов, ошибки изолируем, чтобы не ломать диагностику.
  try {
    const wh = await client.getWebhookSettings(correlationId);
    result.webhook = {
      configured: Boolean(wh.webhooksUri),
      webhooksUri: wh.webhooksUri,
      subscriptions: wh.subscriptions,
    };
  } catch (err) {
    result.webhook = {
      configured: false,
      error: err instanceof Error ? err.message : "Не удалось получить настройки webhook",
    };
  }

  return result;
}
