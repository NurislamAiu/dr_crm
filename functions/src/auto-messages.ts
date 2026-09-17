/**
 * Рубильники автоматических сообщений КЛИЕНТУ — отдельно по каналу.
 *
 * Гасят то, что бот пишет человеку сам, без участия менеджера:
 *   • Telegram — приветствие на /start (приём / обучение / БАДы), ответ
 *     после «Поделиться номером», разовая «Информация о приёме» иногородним;
 *   • WhatsApp — автоответ первому обращению (и текст «мы в отпуске»).
 *
 * Не трогают то, что менеджер запускает руками (быстрые ответы, кнопка
 * «запросить номер», рассылка /promo) и служебные сигналы руководству
 * (вечерняя сводка, «клиент готов оплатить») — это не автоответы клиенту.
 *
 * У ИИ-ботов и догрева свои выключатели: config/aiReply, config/trainingReply,
 * config/followUp. Этот файл — только про заготовленные тексты.
 *
 * config/autoMessages: { telegram: bool, whatsapp: bool }. По умолчанию ОБА
 * ВКЛЮЧЕНЫ — выключаются только явным false, чтобы отсутствие документа в
 * базе не гасило приветствия молча. Общий флаг `enabled` (если стоит false)
 * гасит оба канала разом — старое поведение, для «выключить всё одной
 * командой», совместимо с action=autoall.
 */
import * as admin from "firebase-admin";

const db = () => admin.firestore();

let cache: { telegram: boolean; whatsapp: boolean; at: number } | null = null;

/**
 * Явный флаг канала (true/false) всегда побеждает старый общий `enabled` —
 * иначе «выключить всё» (enabled=false) навсегда мешало бы включить канал
 * обратно точечно: без этого правила запись telegram=true оставалась бы
 * заглушённой старым enabled=false, оставшимся в документе.
 */
function resolve(channelFlag: unknown, legacyEnabled: unknown): boolean {
  if (channelFlag === false) return false;
  if (channelFlag === true) return true;
  return legacyEnabled !== false;
}

async function read(): Promise<{ telegram: boolean; whatsapp: boolean }> {
  if (cache && Date.now() - cache.at < 60_000) return cache;
  try {
    const d = (await db().doc("config/autoMessages").get()).data() ?? {};
    const out = {
      telegram: resolve(d.telegram, d.enabled),
      whatsapp: resolve(d.whatsapp, d.enabled),
    };
    cache = { ...out, at: Date.now() };
    return out;
  } catch {
    return { telegram: true, whatsapp: true }; // сбой чтения не должен оставлять клиентов без ответа
  }
}

export async function telegramAutoMessagesOn(): Promise<boolean> {
  return (await read()).telegram;
}

export async function whatsappAutoMessagesOn(): Promise<boolean> {
  return (await read()).whatsapp;
}
