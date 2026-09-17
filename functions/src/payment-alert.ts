/**
 * «Клиент готов платить» — уведомление руководителю в Telegram.
 *
 * Такие сообщения («готов оплатить», «куда скидывать», «скиньте реквизиты»)
 * — самый горячий момент всей переписки: человек уже решился, и ему нужно
 * выставить счёт. Бот реквизиты отдаёт, но счёт выставляет человек, поэтому
 * о каждом таком сообщении приходит отдельный сигнал — не теряться среди
 * пушей об обычных входящих.
 *
 * Получатели — config/paymentAlert.chatIds, а если он не задан, те же люди,
 * что получают вечернюю сводку (config/dailyReport.chatIds). Выключается
 * через config/paymentAlert.enabled = false.
 */
import * as admin from "firebase-admin";
import { tgCall } from "./telegram/api";
import { reportRecipients } from "./daily-report";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

/**
 * Свой нормализатор, а не общий из topics.ts: тот вычищает всё, кроме a-z и
 * а-я, и казахские буквы (ө, қ, ұ, ә, і, ң, ғ, ү) в нём просто пропадают —
 * «төлеу» превращается в «т леу». Здесь на кону деньги, поэтому оставляем
 * любые буквы любого алфавита.
 */
function norm(s: string): string {
  return (s ?? "")
    .toLowerCase()
    .replace(/ё/g, "е")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()
    .replace(/\s+/g, " ");
}

/**
 * Корни фраз «готов платить». Ищем куском строки, поэтому «оплатит» ловит и
 * «оплатить», и «оплатите»; «төле» — и «төлеу», и «төлеймін», и «төлегім».
 */
const PHRASES = [
  // готовность
  "готов оплатит", "готова оплатит", "готов оплачиват", "готова оплачиват",
  "готов к оплат", "готова к оплат", "готов внест", "готова внест",
  "хочу оплатит", "хочу внест", "могу оплатит", "оплачу", "оплатим",
  "буду оплачиват", "давайте оплат",
  // куда платить
  "как оплатит", "куда оплатит", "куда платит", "куда скидыват", "куда скинут",
  "куда перевест", "куда отправит деньг", "куда закинут", "на какую карт",
  "номер карт", "карта для оплат", "реквизит", "счет на оплат", "выставите счет",
  "выставить счет", "как внести предоплат", "внести предоплат", "внесу предоплат",
  // казахский
  "төле", "ақша аудар", "қалай төле", "қайда төле", "шот шығар",
].map(norm);

export function detectPaymentIntent(text: string): boolean {
  const t = norm(text);
  if (t.length < 3) return false;
  return PHRASES.some((p) => t.includes(p));
}

function topicLabel(topic: unknown): string {
  if (topic === "training") return "обучение";
  if (topic === "supplements") return "БАДы";
  if (topic === "call") return "звонок";
  return "приём";
}

/** «77473193061» → «+7 747 319-30-61»; телеграмный id оставляем как есть. */
function prettyChat(chatId: string, phone: unknown): string {
  const d = String(phone ?? (chatId.startsWith("tg_") ? "" : chatId)).replace(/\D/g, "");
  if (d.length !== 11) return chatId.startsWith("tg_") ? `Telegram ${chatId.replace(/^tg_/, "")}` : chatId;
  return `+${d[0]} ${d.slice(1, 4)} ${d.slice(4, 7)}-${d.slice(7, 9)}-${d.slice(9)}`;
}

/**
 * Шлёт сигнал, если во входящем есть готовность платить.
 *
 * Повторы гасим на полчаса: человек вполне может написать «готов оплатить», а
 * следом «куда скидывать?» — это один и тот же повод выставить счёт, а не два.
 * Право на отправку занимается транзакцией, потому что вебхуки дублируются.
 */
export async function maybePaymentAlert(chatId: string, text: string, tgToken: string): Promise<void> {
  if (!text || !detectPaymentIntent(text)) return;

  const cfg = (await db().doc("config/paymentAlert").get()).data() ?? {};
  if (cfg.enabled === false) return;

  const own = ((cfg.chatIds ?? []) as unknown[])
    .map((v) => String(v).replace(/^tg_/, "").trim())
    .filter((v) => /^\d+$/.test(v));
  const chatIds = own.length > 0 ? own : (await reportRecipients()).chatIds;
  if (chatIds.length === 0) return;

  const convRef = db().doc(`conversations/${chatId}`);
  const claimed = await db().runTransaction(async (tx) => {
    const d = (await tx.get(convRef)).data() ?? {};
    const last = (d.paymentAlertAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    if (Date.now() - last < 30 * 60_000) return false;
    tx.set(convRef, { paymentAlertAt: ts() }, { merge: true });
    return true;
  });
  if (!claimed) return;

  const conv = (await convRef.get()).data() ?? {};
  const body = [
    "💳 Клиент готов оплатить",
    "",
    `${prettyChat(chatId, conv.phone)} · ${topicLabel(conv.topic)}`,
    `«${text.trim().slice(0, 300)}»`,
    "",
    "Нужно выставить счёт.",
  ].join("\n");

  for (const id of chatIds) {
    try {
      await tgCall(tgToken, "sendMessage", { chat_id: Number(id), text: body });
    } catch (e) {
      console.error("paymentAlert send fail", id, String(e instanceof Error ? e.message : e));
    }
  }
}
