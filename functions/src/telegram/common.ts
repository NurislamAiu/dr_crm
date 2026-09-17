import * as admin from "firebase-admin";

/**
 * Общее для Telegram-транспорта: ключи документов, страна по номеру, тексты
 * бота. Telegram-чаты живут в ТЕХ ЖЕ коллекциях, что и WhatsApp
 * (contacts/conversations/messages), но с ключом `tg_<tg_id>` — UI по префиксу
 * понимает, каким транспортом отвечать.
 */

/**
 * Регион задаётся ЯВНО в каждой функции: реэкспорт telegram/* в index.ts
 * исполняется раньше setGlobalOptions, и без этого функции уезжают в
 * us-central1 (а Flutter зовёт callables в europe-west1).
 */
export const TG_REGION = "europe-west1";

export const REGION_HOST = "https://europe-west1-vip-client-manager.cloudfunctions.net";

/** id карточки/диалога: постоянный tg_id клиента. username — НЕ ключ. */
export const tgConvId = (chatId: number | string): string => `tg_${chatId}`;

/**
 * id сообщения: message_id в Telegram уникален только ВНУТРИ чата, поэтому
 * ключ составной. Повторная доставка апдейта попадает в тот же документ.
 */
export const tgMsgDocId = (chatId: number | string, messageId: number | string): string =>
  `tg_${chatId}_${messageId}`;

/** Числовой chat_id из id диалога `tg_...` (null — это не Telegram-чат). */
export function tgChatIdFromConv(convId: string): string | null {
  if (!convId.startsWith("tg_")) return null;
  const raw = convId.slice(3);
  return /^-?\d+$/.test(raw) ? raw : null;
}

/** Из id нашего сообщения `tg_<chat>_<mid>` достаёт message_id Telegram. */
export function tgMessageIdFromDocId(docId: string | undefined | null): number | null {
  if (!docId || !docId.startsWith("tg_")) return null;
  const tail = docId.split("_").pop() ?? "";
  const n = Number(tail);
  return Number.isInteger(n) && n > 0 ? n : null;
}

/**
 * Страна по номеру: `7` + вторая цифра 6/7 → Казахстан, остальные `7…` —
 * Россия, прочие коды — «другая».
 */
export function countryByPhone(digits: string): "kz" | "ru" | "other" {
  if (!digits.startsWith("7")) return "other";
  const second = digits.charAt(1);
  return second === "6" || second === "7" ? "kz" : "ru";
}

/**
 * Отображаемое имя клиента ДО того, как он поделился номером (после — именем
 * становится сам номер). username в списке/шапке не показываем никогда —
 * политика CRM: контакты по номеру. username хранится только в карточке.
 */
export function tgDisplayName(p: {
  firstName?: string | null;
  lastName?: string | null;
  username?: string | null;
  chatId: number | string;
}): string {
  const full = [p.firstName ?? "", p.lastName ?? ""].join(" ").trim();
  if (full) return full;
  return `Telegram ${p.chatId}`;
}

/**
 * Первый телефон из свободного текста клиента («напишу номер сам»).
 * Принимаем: 11 цифр на 7/8 (8 → 7, Казахстан/Россия) и международные
 * с явным «+» (10–15 цифр). Возвращает цифры без «+», либо null.
 */
export function extractPhoneFromText(text: string): string | null {
  const re = /\+?\d[\d\s\-()]{8,17}\d/g;
  for (const m of text.match(re) ?? []) {
    const hadPlus = m.trim().startsWith("+");
    let d = m.replace(/\D/g, "");
    if (d.length === 11 && d.startsWith("8")) d = `7${d.slice(1)}`;
    if (d.length === 11 && d.startsWith("7")) return d;
    if (hadPlus && d.length >= 10 && d.length <= 15) return d;
  }
  return null;
}

/** Подписи медиа для превью в списке чатов и пушей. */
export const TG_KIND_LABEL: Record<string, string> = {
  image: "📷 Фото",
  audio: "🎤 Голосовое",
  video: "🎬 Видео",
  document: "📄 Файл",
};

export function tgPreview(type: string, text: string | null): string {
  if (text && text.length > 0) return text.slice(0, 120);
  return TG_KIND_LABEL[type] ?? `[${type}]`;
}

// ── Тексты бота (config/telegram, правятся из приложения без передеплоя) ──

export interface TgTexts {
  greeting: string;
  /** Приветствие для темы «обучение» — вместо пациентского. */
  greetingTraining: string;
  /** Приветствие для темы «БАДы» — вместо пациентского. */
  greetingSupplements: string;
  afterContact: string;
  shareButton: string;
  /** Запрос номера по кнопке из шапки чата (пока номера нет). */
  askPhone: string;
  /** «Информация о приёме» — авто-отправка иногородним (номер не КЗ), 1 раз. */
  foreignInfo: string;
  /** Пост для команды /promo: пересылается в чаты, кнопка сохраняется. */
  promoText: string;
  promoButton: string;
  promoUrl: string;
}

export const TG_DEFAULT_TEXTS: TgTexts = {
  // Первое, что видит клиент на /start. Кнопка «Поделиться номером» идёт
  // под этим же сообщением — отдельная строка про неё не нужна.
  greeting: [
    "Здравствуйте!",
    "",
    "Подскажите, пожалуйста:",
    "• что вас беспокоит?",
    "• какое гражданство у пациента?",
    "",
    "Это нужно, чтобы подобрать приём и назвать точную стоимость.",
  ].join("\n"),
  // Ученикам — своё приветствие: пациентская информация о приёме им не к
  // месту. Текст согласован с быстрыми ответами «Обучение · …».
  greetingTraining: [
    "Здравствуйте! Спасибо за интерес к обучению у доктора Тойтаева. 🙌",
    "",
    "Это авторская методика остеопатии — от диагностики руками до результата. Обучение очное, в Астане: личное наставничество и работа с реальными пациентами под контролем доктора. В группу берём всего 20 человек.",
    "",
    "Чтобы попасть в группу, заполните анкету на сайте — это 3 шага, около 3 минут:",
    "https://dr-site-toitayev.web.app/",
    "",
    "Доктор читает каждую анкету лично. Как заполните — напишите нам, и менеджер подскажет следующий шаг.",
  ].join("\n"),
  // Покупателям БАДов — короткое приветствие без пациентских вопросов.
  greetingSupplements: [
    "Здравствуйте! Спасибо за интерес к БАДам доктора Тойтаева. 🌿",
    "",
    "Напишите, пожалуйста, что вас интересует — менеджер подскажет по составу, наличию, ценам и доставке.",
  ].join("\n"),
  // Короткое подтверждение после кнопки: вопросы уже заданы в приветствии,
  // повторять их не нужно.
  afterContact: "Спасибо, номер получен! Менеджер свяжется с вами в ближайшее время.",
  shareButton: "📱 Поделиться номером",
  askPhone: "Напишите нам, пожалуйста, ваш номер телефона — или нажмите кнопку ниже 👇",
  foreignInfo: [
    "ℹ️ Информация о приёме",
    "",
    "Пациенты из других городов и стран, по возможности, проходят консультацию и процедуру за один визит. Возможность проведения процедуры определяется индивидуально после оценки состояния.",
    "",
    "Возьмите с собой МРТ (если есть) и удостоверение личности/паспорт.",
    "",
    "Для предварительной консультации отправьте диагноз, основные жалобы и возраст пациента.",
    "",
    "✅ ПРИНИМАЕМ: Грыжи, Протрузии, Остеопороз (консультация), Артроз, Артрит, Коксартроз, Вальгус, Давление, Сахарный диабет (консультация), Стенты, Гонартроз, Жидкость в коленях, Сколиоз, Сутулость, Стеноз (консультация), ЗПР, ЗПРР",
    "",
    "❌ ПРОТИВОПОКАЗАНИЯ: Инсульт, Паралич, После операции — 1 год реабилитации, Инфаркт, РАС, Кардиостимулятор, Беременность, Эпилепсия, Аутизм, ДЦП, Цикл, ОРВИ",
    "",
    "🌍 Для пациентов из других стран",
    "",
    "Цены указаны в тенге (₸).",
    "",
    "Стандарт — 230 000 ₸",
    "• Предоплата — 6 000 ₽",
    "",
    "VIP — 460 000 ₸",
    "• Предоплата — 12 000 ₽",
    "",
    "Остаток оплачивается в тенге вне зависимости от курса.",
    "",
    "VIP включает:",
    "• приём и процедуру",
    "• организацию трансфера",
    "• помощь с бронированием отеля (отель оплачивается отдельно)",
    "• персональное сопровождение",
    "",
    "📋 Рекомендации после сеанса",
    "",
    "В течение 14 дней рекомендуется исключить:",
    "• баню, сауну и бассейн;",
    "• интенсивные физические нагрузки;",
    "• поднятие тяжестей.",
    "",
    "После процедуры могут временно наблюдаться лёгкая слабость, сонливость, ломота в мышцах или кратковременное усиление прежних болевых ощущений.",
    "",
    "Если симптомы выражены, усиливаются или сохраняются длительное время, необходимо обратиться к врачу.",
  ].join("\n"),
  promoText:
    "Клиника DR.TOITAYEV теперь в Telegram!\n\n" +
    "Запись и консультации — в пару нажатий: нажмите кнопку ниже, затем «Начать» " +
    "и поделитесь номером. Менеджер свяжется с вами в ближайшее время.",
  promoButton: "📲 Написать менеджеру",
  promoUrl: "https://t.me/TOITAYEV_BOT?start=promo",
};

export async function tgTexts(): Promise<TgTexts> {
  const cfg = (await admin.firestore().doc("config/telegram").get()).data() ?? {};
  // Поле из config/telegram, а пустое/не заданное — значение по умолчанию.
  const pick = (key: keyof TgTexts): string => {
    const v = cfg[key];
    return typeof v === "string" && v ? v : TG_DEFAULT_TEXTS[key];
  };
  return {
    greeting: pick("greeting"),
    greetingTraining: pick("greetingTraining"),
    greetingSupplements: pick("greetingSupplements"),
    afterContact: pick("afterContact"),
    shareButton: pick("shareButton"),
    askPhone: pick("askPhone"),
    foreignInfo: pick("foreignInfo"),
    promoText: pick("promoText"),
    promoButton: pick("promoButton"),
    promoUrl: pick("promoUrl"),
  };
}
