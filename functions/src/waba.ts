/**
 * WhatsApp Business API (WABA).
 *
 * У Wazzup один и тот же роут отправки и для QR-канала, и для WABA — меняется
 * только канал. Отличия WABA, ради которых нужен этот модуль:
 *
 *  1. Написать первым (или после 24 часов молчания клиента) можно только
 *     шаблоном, одобренным Meta.
 *  2. Внутри 24 часов после сообщения клиента — обычный текст, как сейчас.
 *
 * Поэтому здесь: какой канал сейчас используется (QR или WABA), открыто ли
 * окно в конкретном чате и какой шаблон брать для «первого касания».
 */
import * as admin from "firebase-admin";
import { wazzupChannels, type WazzupChannel } from "./wazzup";

const db = () => admin.firestore();

/** transport из Wazzup: whatsapp — QR-канал, wapi — WABA. */
export const isWaba = (transport: string) => transport === "wapi";

/** Окно свободной переписки после сообщения клиента. */
export const WINDOW_MS = 24 * 60 * 60 * 1000;

export type ChannelInfo = { channelId: string; transport: string; state: string; phone: string };

let chCache: { v: ChannelInfo; at: number } | null = null;

/**
 * Канал, через который работаем. Приоритет:
 *   1) config/channel.channelId — чтобы переключиться на WABA из приложения,
 *      без передеплоя функций;
 *   2) секрет WAZZUP_CHANNEL_ID.
 * Транспорт и состояние берём из Wazzup (кэш 5 минут).
 */
export async function currentChannel(apiKey: string, secretChannelId: string): Promise<ChannelInfo> {
  if (chCache && Date.now() - chCache.at < 5 * 60_000) return chCache.v;

  let wanted = secretChannelId;
  try {
    const cfg = (await db().doc("config/channel").get()).data();
    const override = String(cfg?.channelId ?? "").trim();
    if (override) wanted = override;
  } catch {
    /* нет доступа к конфигу — работаем по секрету */
  }

  let info: ChannelInfo = { channelId: wanted, transport: "whatsapp", state: "unknown", phone: "" };
  try {
    const list = await wazzupChannels(apiKey);
    const ch: WazzupChannel | undefined = list.find((c) => c.channelId === wanted) ?? list[0];
    if (ch) info = { channelId: ch.channelId, transport: ch.transport, state: ch.state, phone: ch.plainId };
  } catch {
    /* Wazzup недоступен — считаем канал обычным QR, поведение как раньше */
  }
  chCache = { v: info, at: Date.now() };
  return info;
}

/** Сбросить кэш канала (после переключения канала из приложения). */
export const resetChannelCache = () => {
  chCache = null;
};

/**
 * Открыто ли 24-часовое окно: писал ли клиент за последние сутки.
 * lastInboundAt проставляет вебхук на каждом входящем.
 */
export async function windowOpen(chatId: string): Promise<boolean> {
  try {
    const d = (await db().doc(`conversations/${chatId}`).get()).data();
    const last = (d?.lastInboundAt as admin.firestore.Timestamp | undefined)?.toDate();
    if (!last) return false;
    return Date.now() - last.getTime() < WINDOW_MS;
  } catch {
    return false;
  }
}

export type WabaSettings = {
  /** Шаблон «первого касания»: им зовём клиента в чат, когда окно закрыто. */
  openerTemplateId: string;
  /** Что подставлять в переменные шаблона: name | date | text. */
  openerVars: string[];
  /** Не слать приглашение чаще, чем раз в N часов на один чат. */
  openerCooldownHours: number;
};

const DEFAULTS: WabaSettings = { openerTemplateId: "", openerVars: ["name"], openerCooldownHours: 24 };

let cfgCache: { v: WabaSettings; at: number } | null = null;

/** Настройки WABA (config/waba), кэш на минуту. */
export async function wabaSettings(): Promise<WabaSettings> {
  if (cfgCache && Date.now() - cfgCache.at < 60_000) return cfgCache.v;
  let v = { ...DEFAULTS };
  try {
    const d = (await db().doc("config/waba").get()).data() ?? {};
    v = {
      openerTemplateId: String(d.openerTemplateId ?? "").trim(),
      openerVars: ((d.openerVars ?? DEFAULTS.openerVars) as unknown[]).map(String),
      openerCooldownHours:
        typeof d.openerCooldownHours === "number" ? Math.max(1, d.openerCooldownHours) : DEFAULTS.openerCooldownHours,
    };
  } catch {
    /* по умолчанию */
  }
  cfgCache = { v, at: Date.now() };
  return v;
}

export const resetWabaCache = () => {
  cfgCache = null;
};

/** Значения переменных шаблона по описанию openerVars. */
export function templateValues(vars: string[], ctx: { name?: string; date?: string; text?: string }): string[] {
  return vars.map((v) => {
    switch (v) {
      case "name":
        return (ctx.name ?? "").trim() || "клиент";
      case "date":
        return (ctx.date ?? "").trim();
      case "text":
        return (ctx.text ?? "").trim().slice(0, 500);
      default:
        return v; // фиксированное значение прямо из настроек
    }
  });
}

/**
 * Уже звали этого клиента шаблоном недавно? Чтобы не слать приглашение на
 * каждое сообщение менеджера, пока клиент молчит.
 */
export async function openerRecentlySent(chatId: string, cooldownHours: number): Promise<boolean> {
  try {
    const d = (await db().doc(`conversations/${chatId}`).get()).data();
    const last = (d?.lastOpenerAt as admin.firestore.Timestamp | undefined)?.toDate();
    if (!last) return false;
    return Date.now() - last.getTime() < cooldownHours * 3600_000;
  } catch {
    return false;
  }
}

export async function markOpenerSent(chatId: string): Promise<void> {
  try {
    await db()
      .doc(`conversations/${chatId}`)
      .set({ lastOpenerAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
  } catch {
    /* не критично */
  }
}
