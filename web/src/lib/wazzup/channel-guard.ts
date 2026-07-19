import { getEnv } from "@/lib/env";
import { getWazzupClient } from "./factory";
import { evaluateChannelState, findWhatsappChannel } from "./channel-state";
import type { WazzupApiClient } from "./client";

/**
 * Проверка, что целевой WhatsApp-канал в состоянии active перед отправкой
 * (ТЗ §5, §12). Результат кэшируется на короткое время, чтобы не упираться
 * в лимиты GET /channels (§26).
 */

export interface ChannelGuardResult {
  channelId: string | null;
  canSend: boolean;
  state: string | null;
  /** Понятное сообщение, если отправка заблокирована. */
  reason: string | null;
}

interface CacheEntry {
  value: ChannelGuardResult;
  expiresAt: number;
}

const CACHE_TTL_MS = 10_000;
let cache: CacheEntry | null = null;

export function invalidateChannelGuardCache(): void {
  cache = null;
}

export async function resolveSendableChannel(
  client: WazzupApiClient = getWazzupClient(),
  now: number = Date.now(),
): Promise<ChannelGuardResult> {
  if (cache && cache.expiresAt > now) return cache.value;

  const env = getEnv();
  let value: ChannelGuardResult;
  try {
    const channels = await client.getChannels();
    const target = findWhatsappChannel(channels, { expectedChannelId: env.WAZZUP_CHANNEL_ID });
    if (!target) {
      value = { channelId: null, canSend: false, state: null, reason: "WhatsApp-канал не найден в Wazzup." };
    } else {
      const status = evaluateChannelState(target.state);
      value = {
        channelId: target.channelId,
        canSend: status.canSend,
        state: target.state,
        reason: status.canSend ? null : status.adminMessage,
      };
    }
  } catch {
    // Не смогли проверить канал — безопаснее заблокировать отправку.
    value = { channelId: null, canSend: false, state: null, reason: "Не удалось проверить состояние канала Wazzup." };
  }

  cache = { value, expiresAt: now + CACHE_TTL_MS };
  return value;
}
