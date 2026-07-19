import { getRedis } from "@/lib/redis";

/**
 * Realtime-события (ТЗ §23). Публикуются в Redis pub/sub; отдельный Socket.IO
 * сервер (src/realtime/server.ts) ретранслирует их подключённым клиентам
 * (Flutter-приложение, админка) в комнаты своей организации/диалога.
 *
 * Такое разделение позволяет worker'у и API-роутам публиковать события, не
 * завися от жизненного цикла WebSocket-сервера.
 */

export const REALTIME_CHANNEL = "realtime:events";

export type RealtimeEventName =
  | "conversation.created"
  | "conversation.updated"
  | "conversation.assigned"
  | "message.created"
  | "message.updated"
  | "message.status.updated"
  | "channel.state.updated"
  | "notification.created"
  | "user.typing";

export interface RealtimeEvent {
  event: RealtimeEventName;
  organizationId: string;
  /** Комната диалога — если событие относится к конкретному диалогу. */
  conversationId?: string;
  /** Кому адресовано (например, notification конкретному менеджеру). */
  userId?: string;
  payload: unknown;
  ts: string;
}

/** Опубликовать realtime-событие (fire-and-forget, ошибки не роняют пайплайн). */
export async function publishRealtime(evt: Omit<RealtimeEvent, "ts">): Promise<void> {
  const message: RealtimeEvent = { ...evt, ts: new Date().toISOString() };
  try {
    await getRedis().publish(REALTIME_CHANNEL, JSON.stringify(message));
  } catch {
    // Realtime — best-effort. Данные уже в БД; клиент подхватит при reconnect
    // через event cursor (ТЗ §23).
  }
}
