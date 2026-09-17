/**
 * Автоответ WhatsApp на первое обращение клиента.
 *
 * Отличие от автоответа Wazzup, который мы заменяем: тот уходил ШАБЛОНОМ, а
 * шаблон для Meta — «переписка, начатая компанией». 201 срабатывание в сутки
 * съедало почти весь лимит 250. Наш уходит обычным текстом внутри открытого
 * 24-часового окна: не тратит лимит и ничего не стоит.
 *
 * Правила (заданы владельцем 2026-08-10):
 *  • только когда окно открыто (клиент только что написал);
 *  • РОВНО ОДИН РАЗ на чат за всё время — повторно никогда;
 *  • 10+ равнозначных вариантов текста, чтобы 200 сообщений в день не были
 *    одинаковыми;
 *  • если менеджер успел ответить сам — автоответ отменяется.
 */
import * as admin from "firebase-admin";
import { randomUUID } from "crypto";
import { enqueue } from "./limits";
import { uniquifyText } from "./variate";
import { vacationCfg, vacationText } from "./vacation";
import { whatsappAutoMessagesOn } from "./auto-messages";
import { windowOpen } from "./waba";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

/**
 * Вопросы клиенту — во всех вариантах одинаково. Меняются только
 * приветственная и завершающая строки: этого достаточно, чтобы сообщения не
 * были побайтово идентичными, а сами вопросы клиент читает всегда в одной
 * формулировке.
 *
 * Гражданство спрашиваем не из любопытства: от него зависит прайс (для
 * казахстанцев одна цена, для остальных другая), и без ответа менеджер не
 * может назвать стоимость.
 */
const WA_QUESTIONS = [
  "Подскажите, пожалуйста:",
  "• что вас беспокоит?",
  "• какое гражданство у пациента?",
  "",
  "Это нужно, чтобы подобрать приём и назвать точную стоимость.",
].join("\n");

const WA_OPENINGS = [
  "Спасибо за обращение!",
  "Здравствуйте! Спасибо за обращение.",
  "Благодарим за обращение!",
  "Спасибо, что написали нам!",
  "Здравствуйте! Ваше сообщение получено.",
  "Добрый день! Спасибо за обращение.",
];

const WA_CLOSINGS = [
  "Наш менеджер свяжется с вами в ближайшее время.",
  "Менеджер свяжется с вами в ближайшее время.",
];

/** Варианты автоответа: приветствие × концовка, вопросы неизменны. */
export const WA_AUTOREPLY_VARIANTS: string[] = WA_OPENINGS.flatMap((open) =>
  WA_CLOSINGS.map((close) => `${open}\n\n${WA_QUESTIONS}\n\n${close}`),
);

/**
 * Автоответы разделены по темам: приём / обучение / БАДы. Обращений по темам
 * в разы меньше, чем пациентских, поэтому вариантов хватает нескольких —
 * плюс невидимая уникализация текста при отправке.
 */
const WA_TRAINING_BODY =
  "Обучение очное, в Астане: авторская методика остеопатии доктора Тойтаева, " +
  "личное наставничество и практика на реальных пациентах. В группе всего 20 мест.\n\n" +
  "Чтобы попасть в группу, заполните анкету на сайте (около 3 минут):\n" +
  "https://dr-site-toitayev.web.app/";

export const WA_TRAINING_VARIANTS: string[] = [
  "Здравствуйте! Спасибо за интерес к обучению у доктора Тойтаева.",
  "Добрый день! Спасибо за интерес к обучению у доктора Тойтаева.",
  "Здравствуйте! Ваше сообщение получено — спасибо за интерес к обучению.",
].map((open) => `${open}\n\n${WA_TRAINING_BODY}\n\nКак заполните — напишите нам, менеджер подскажет следующий шаг.`);

export const WA_SUPPLEMENT_VARIANTS: string[] = [
  "Здравствуйте! Спасибо за интерес к БАДам доктора Тойтаева.",
  "Добрый день! Спасибо за интерес к БАДам доктора Тойтаева.",
  "Здравствуйте! Ваше сообщение получено — спасибо за интерес к БАДам.",
].map((open) => `${open}\n\nНапишите, пожалуйста, что вас интересует — менеджер подскажет по составу, наличию, ценам и доставке.`);

type Cfg = {
  enabled: boolean;
  delaySec: number;
  variants: string[];
  trainingVariants: string[];
  supplementVariants: string[];
};

/** Настройки автоответа (config/waAutoReply). Правит только админ. */
async function cfg(): Promise<Cfg> {
  const strings = (v: unknown): string[] =>
    ((v ?? []) as unknown[]).filter((s): s is string => typeof s === "string" && s.trim().length > 0);
  try {
    const d = (await db().doc("config/waAutoReply").get()).data() ?? {};
    const list = strings(d.variants);
    const delay = Number(d.delaySec);
    return {
      // ПО УМОЛЧАНИЮ ВЫКЛЮЧЕН. Включается только явным enabled=true в
      // config/waAutoReply. 2026-08-10: из-за прежнего умолчания «включён»
      // автоответ ушёл давним клиентам, а не только новым.
      enabled: d.enabled === true,
      delaySec: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 120) : 8,
      variants: list.length > 0 ? list : WA_AUTOREPLY_VARIANTS,
      trainingVariants: strings(d.trainingVariants).length > 0 ? strings(d.trainingVariants) : WA_TRAINING_VARIANTS,
      supplementVariants:
        strings(d.supplementVariants).length > 0 ? strings(d.supplementVariants) : WA_SUPPLEMENT_VARIANTS,
    };
  } catch {
    return {
      enabled: true,
      delaySec: 8,
      variants: WA_AUTOREPLY_VARIANTS,
      trainingVariants: WA_TRAINING_VARIANTS,
      supplementVariants: WA_SUPPLEMENT_VARIANTS,
    };
  }
}

/**
 * Ставит автоответ в очередь, если этому чату он ещё никогда не отправлялся.
 * Отметку waAutoReplyAt ставим ДО отправки и в транзакции: два сообщения
 * клиента подряд не должны дать два автоответа.
 */
export async function maybeWaAutoReply(chatId: string): Promise<void> {
  // Общий рубильник автосообщений клиенту — выключен, значит менеджеры
  // здороваются сами (см. auto-messages.ts).
  if (!(await whatsappAutoMessagesOn())) return;
  const c = await cfg();
  if (!c.enabled) return;
  if (!(await windowOpen(chatId))) return; // вне окна — не шлём ничего

  const convRef = db().doc(`conversations/${chatId}`);

  // Автоответы разделены по темам: приём / обучение / БАДы. Пациентские
  // вопросы («что беспокоит», «гражданство пациента») уходят только
  // пациентам; ученикам и покупателям БАДов — свои тексты.
  const conv = (await convRef.get()).data() ?? {};
  const pool = conv.topic === "training"
      ? c.trainingVariants
      : conv.topic === "supplements"
          ? c.supplementVariants
          : c.variants;

  // ТОЛЬКО НОВЫЙ КЛИЕНТ. Если в переписке уже есть сообщения старше 10 минут,
  // это давний чат — автоответ «Спасибо за обращение» там неуместен. Ставим
  // отметку, чтобы такой чат больше никогда не проверялся.
  const first = await db()
    .collection("messages")
    .where("conversationId", "==", chatId)
    .orderBy("createdAt", "asc")
    .limit(1)
    .get();
  const firstAt = (first.docs[0]?.data()?.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? Date.now();
  if (Date.now() - firstAt > 10 * 60_000) {
    await convRef.set({ waAutoReplyAt: ts(), waAutoReplySkip: "давний чат" }, { merge: true });
    return;
  }

  const claimed = await db().runTransaction(async (tx) => {
    const snap = await tx.get(convRef);
    const d = snap.data() ?? {};
    if (d.blocked === true) return false;
    if (d.waAutoReplyAt) return false; // уже отправляли — больше никогда
    tx.set(convRef, { waAutoReplyAt: ts() }, { merge: true });
    return true;
  });
  if (!claimed) return;

  // Отпуск/недоступны: если включено — вместо обычного приветствия (тема
  // роли не играет, отвечать всё равно некому). Тот же строгий отбор «только
  // новый клиент» выше уже отсёк давние чаты — сюда попадают именно новые.
  const vac = await vacationCfg();
  if (vac.enabled) {
    await enqueue({
      kind: "text",
      chatId,
      text: vacationText(vac, chatId),
      authorId: "auto",
      crmMessageId: randomUUID(),
      reason: "delay",
      autoReply: true,
      nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + c.delaySec * 1000),
    });
    return;
  }

  // Случайный вариант из пула своей темы — соседние клиенты получают разные
  // тексты. Плюс невидимая уникализация внутри варианта.
  const idx = Math.floor(Math.random() * pool.length);
  const text = uniquifyText(pool[idx] ?? pool[0] ?? WA_AUTOREPLY_VARIANTS[0]!, chatId);

  await enqueue({
    kind: "text",
    chatId,
    text,
    authorId: "auto",
    crmMessageId: randomUUID(),
    reason: "delay",
    autoReply: true,
    nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + c.delaySec * 1000),
  });
}

/**
 * Отменять ли автоответ в момент отправки: менеджер уже успел ответить сам.
 * Проверяется в onOutboxCreated прямо перед уходом сообщения.
 */
export async function autoReplyStillNeeded(chatId: string, createdAtMs: number): Promise<boolean> {
  try {
    const snap = await db()
      .collection("messages")
      .where("conversationId", "==", chatId)
      .orderBy("createdAt", "desc")
      .limit(10)
      .get();
    for (const d of snap.docs) {
      const x = d.data();
      if (x.direction !== "outbound") continue;
      const author = String(x.authorId ?? "");
      if (!author || author === "auto") continue; // не менеджер
      const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      if (at >= createdAtMs - 2000) return false; // менеджер опередил
    }
    return true;
  } catch {
    return true;
  }
}
