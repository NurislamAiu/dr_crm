import type { Channel } from "./schemas";

/**
 * Отображение состояния канала в поведение CRM (ТЗ §5, architecture.md §5).
 * ВАЖНО: QR-состояние называется `qr` (не `qridle`, как в ТЗ) — см. §1 п.1.
 */

export interface ChannelStatus {
  /** Разрешена ли отправка сообщений. */
  canSend: boolean;
  /** Требуется ли действие администратора. */
  needsAttention: boolean;
  /** Текст предупреждения для администратора (или null, если всё хорошо). */
  adminMessage: string | null;
  /** Нормализованное состояние (для сравнения без учёта регистра). */
  normalizedState: string;
}

const MESSAGES: Record<string, string> = {
  active: "",
  init: "Канал запускается, подождите.",
  qr: "Необходимо повторно отсканировать QR-код в Wazzup.",
  phoneunavailable: "Wazzup потерял связь с телефоном.",
  openelsewhere: "WhatsApp открыт в другом месте.",
  notenoughmoney: "Канал WhatsApp не оплачен.",
  foreignphone: "QR-код отсканирован другим номером телефона.",
  unauthorized: "Канал WhatsApp не авторизован.",
  waitforpassword: "Канал ожидает пароль двухфакторной аутентификации.",
  disabled: "Канал отключён или снят с подписки.",
};

export function evaluateChannelState(state: string): ChannelStatus {
  const norm = state.trim().toLowerCase();
  const isActive = norm === "active";
  const known = norm in MESSAGES;

  return {
    canSend: isActive,
    needsAttention: !isActive,
    adminMessage: isActive
      ? null
      : (MESSAGES[norm] ?? `Неизвестное состояние канала: "${state}".`),
    normalizedState: norm,
  };
}

/**
 * Найти целевой WhatsApp-канал среди списка каналов.
 * ТЗ §5: искать transport==="whatsapp" (НЕ выбирать wapi автоматически).
 * Если задан expectedChannelId — приоритет ему; иначе первый whatsapp-канал
 * (опционально сузить по plainId).
 */
export function findWhatsappChannel(
  channels: readonly Channel[],
  opts: { expectedChannelId?: string | undefined; expectedPlainId?: string | undefined } = {},
): Channel | null {
  const whatsapp = channels.filter((c) => c.transport === "whatsapp");
  if (opts.expectedChannelId) {
    const byId = whatsapp.find((c) => c.channelId === opts.expectedChannelId);
    if (byId) return byId;
  }
  if (opts.expectedPlainId) {
    const byPlain = whatsapp.find(
      (c) => c.plainId.replace(/\D/g, "") === opts.expectedPlainId!.replace(/\D/g, ""),
    );
    if (byPlain) return byPlain;
  }
  return whatsapp[0] ?? null;
}
