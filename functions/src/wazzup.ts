/** chatId для whatsapp — только цифры (как в текущем backend). */
export function normalizeChatId(chatType: string, chatId: string): string {
  if (chatType === "whatsapp") return chatId.replace(/\D/g, "");
  return chatId.trim();
}

/** Дата сообщения Wazzup (ISO) → миллисекунды, либо null. */
export function parseDateMs(v: unknown): number | null {
  if (typeof v !== "string") return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
}

export interface WazzupMessage {
  messageId?: string;
  chatId?: string;
  chatType?: string;
  type?: string;
  text?: string | null;
  contentUri?: string | null;
  isEcho?: boolean;
  status?: string;
  dateTime?: string;
  authorName?: string | null;
  channelId?: string;
  /** Для status=error приходит причина (структура как в statuses). */
  error?: unknown;
}

export interface WazzupStatus {
  messageId?: string;
  status?: string;
  timestamp?: string;
  /** Для status=error Wazzup присылает причину — её и показываем менеджеру. */
  error?: unknown;
  errorDescription?: string;
  description?: string;
}

/**
 * POST /v3/message — отправка текста через Wazzup. Возвращает messageId.
 *
 * Тот же роут обслуживает и обычный WhatsApp (QR), и WABA — отличие лишь в
 * канале. Для WABA вне 24-часового окна вместо text передаётся одобренный
 * Meta шаблон: templateId + значения переменных.
 */
/**
 * Код шаблона WABA для поля text: «@template: <guid> { [[знач1]]; [[знач2]] }».
 * Ровно в таком виде его отдаёт сам Wazzup в поле templateCode — значения
 * подставляем вместо заготовок [[bodyVarN]].
 */
export function wabaTemplateCode(guid: string, values: string[]): string {
  // Скобки и «;» внутри значения ломают разбор кода — вычищаем.
  const clean = (v: string) => v.replace(/[[\]{};]/g, " ").replace(/\s+/g, " ").trim();
  return `@template: ${guid} { ${values.map((v) => `[[${clean(v)}]]`).join("; ")} }`;
}

export async function wazzupSendText(
  apiKey: string,
  input: {
    channelId: string;
    chatId: string;
    chatType: string;
    text: string;
    crmMessageId: string;
    refMessageId?: string;
    templateId?: string;
    templateValues?: string[];
  },
): Promise<{ messageId?: string }> {
  const template = (input.templateId ?? "").trim();
  const res = await fetch("https://api.wazzup24.com/v3/message", {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({
      channelId: input.channelId,
      chatId: input.chatId,
      chatType: input.chatType,
      // Шаблон уходит КОДОМ в поле text (документированный формат Wazzup).
      // С параметром templateId сообщение уходило как обычный текст, и Meta
      // отбивала его с 24_HOURS_EXCEEDED — окно у молчащего клиента закрыто.
      ...(template
        ? { text: wabaTemplateCode(template, input.templateValues ?? []) }
        : { text: input.text }),
      crmMessageId: input.crmMessageId,
      ...(input.refMessageId ? { refMessageId: input.refMessageId } : {}),
      clearUnanswered: true,
    }),
  });
  const data = (await res.json().catch(() => ({}))) as { messageId?: string; error?: unknown };
  if (!res.ok) throw new Error(`Wazzup ${res.status}: ${JSON.stringify(data)}`);
  return { messageId: data.messageId };
}

/** Канал Wazzup: transport «whatsapp» — QR, «wapi» — WABA. */
export type WazzupChannel = { channelId: string; transport: string; plainId: string; state: string };

/** GET /v3/channels — список каналов аккаунта. */
export async function wazzupChannels(apiKey: string): Promise<WazzupChannel[]> {
  const res = await fetch("https://api.wazzup24.com/v3/channels", {
    headers: { authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) throw new Error(`Wazzup channels ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as unknown;
  const list = (Array.isArray(body) ? body : ((body as { data?: unknown[] }).data ?? [])) as Record<string, unknown>[];
  return list.map((c) => ({
    channelId: String(c.channelId ?? ""),
    transport: String(c.transport ?? ""),
    plainId: String(c.plainId ?? c.name ?? ""),
    state: String(c.state ?? "unknown"),
  }));
}

/** Компонент шаблона WABA (HEADER / BODY / FOOTER / BUTTONS). */
export type WabaComponent = { type?: string; format?: string; text?: string; buttons?: unknown[] };

/** Шаблон WABA из личного кабинета Wazzup. */
export type WabaTemplate = {
  templateGuid: string;
  title: string;
  name: string;
  category: string;
  language: string;
  status: string;
  channels: string[];
  components: WabaComponent[];
  templateCode?: string;
};

/** GET /v3/templates/whatsapp — шаблоны WABA, одобренные Meta. */
export async function wazzupTemplates(apiKey: string, limit = 100, offset = 0): Promise<WabaTemplate[]> {
  const res = await fetch(`https://api.wazzup24.com/v3/templates/whatsapp?limit=${limit}&offset=${offset}`, {
    headers: { authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) throw new Error(`Wazzup templates ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as unknown;
  const list = (Array.isArray(body) ? body : ((body as { data?: unknown[] }).data ?? [])) as Record<string, unknown>[];
  return list.map((t) => ({
    templateGuid: String(t.templateGuid ?? ""),
    title: String(t.title ?? ""),
    name: String(t.name ?? ""),
    category: String(t.category ?? ""),
    language: String(t.language ?? ""),
    status: String(t.status ?? ""),
    channels: ((t.channels ?? []) as unknown[]).map(String),
    components: ((t.components ?? []) as WabaComponent[]) ?? [],
    templateCode: t.templateCode ? String(t.templateCode) : undefined,
  }));
}

/** PATCH /v3/message/:id — редактирование текста. */
export async function wazzupEditText(apiKey: string, messageId: string, text: string): Promise<void> {
  const res = await fetch(`https://api.wazzup24.com/v3/message/${encodeURIComponent(messageId)}`, {
    method: "PATCH",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({ text }),
  });
  if (!res.ok) throw new Error(`Wazzup edit ${res.status}: ${await res.text()}`);
}

/** DELETE /v3/message/:id — удаление. */
export async function wazzupDeleteMessage(apiKey: string, messageId: string): Promise<void> {
  const res = await fetch(`https://api.wazzup24.com/v3/message/${encodeURIComponent(messageId)}`, {
    method: "DELETE",
    headers: { authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) throw new Error(`Wazzup delete ${res.status}: ${await res.text()}`);
}

/** POST /v3/message — отправка медиа по публичной ссылке contentUri. */
export async function wazzupSendMedia(
  apiKey: string,
  input: { channelId: string; chatId: string; chatType: string; contentUri: string; crmMessageId: string },
): Promise<{ messageId?: string }> {
  const res = await fetch("https://api.wazzup24.com/v3/message", {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({
      channelId: input.channelId,
      chatId: input.chatId,
      chatType: input.chatType,
      contentUri: input.contentUri,
      crmMessageId: input.crmMessageId,
      clearUnanswered: true,
    }),
  });
  const data = (await res.json().catch(() => ({}))) as { messageId?: string };
  if (!res.ok) throw new Error(`Wazzup ${res.status}: ${JSON.stringify(data)}`);
  return { messageId: data.messageId };
}

/** Тип медиа по MIME → как в приложении (image/audio/video/document). */
export function kindForMime(mime: string): string {
  if (mime.startsWith("image/")) return "image";
  if (mime.startsWith("audio/")) return "audio";
  if (mime.startsWith("video/")) return "video";
  return "document";
}
