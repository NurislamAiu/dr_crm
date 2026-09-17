/**
 * Быстрые ответы как база знаний для автоответчиков.
 *
 * Один загрузчик на всех: и пациентский ИИ, и автоответчик по обучению берут
 * тексты отсюда, чтобы менеджер правил их в одном месте — в приложении, — а
 * не в коде. Кэш на 5 минут: правка быстрого ответа доезжает до бота сама,
 * без деплоя, но и Firestore не дёргается на каждое сообщение.
 *
 * Разделы «Обучение · …» и всё остальное живут в одной коллекции, но
 * сценарии у них разные (пациент и ученик), поэтому наружу отдаются
 * раздельно — смешивать их в одном промпте нельзя: ученику не нужны цены
 * приёма, пациенту — стоимость обучения.
 */
import * as admin from "firebase-admin";

const db = () => admin.firestore();

export type QuickReply = { title: string; text: string };

/** Заголовки раздела обучения — по префиксу «Обучение», как их ведёт менеджер. */
export function isTrainingTitle(title: string): boolean {
  return title.toLowerCase().startsWith("обучение");
}

let cache: { items: QuickReply[]; at: number } | null = null;

async function all(): Promise<QuickReply[]> {
  if (cache && Date.now() - cache.at < 5 * 60_000) return cache.items;
  const snap = await db().collection("quickReplies").limit(200).get();
  const items = snap.docs
    .map((d) => ({ title: String(d.data().title ?? "").trim(), text: String(d.data().text ?? "").trim() }))
    .filter((q) => q.title && q.text);
  cache = { items, at: Date.now() };
  return items;
}

/** Пациентская база — без раздела обучения, у него свой сценарий и свои тексты. */
export async function patientKnowledge(): Promise<QuickReply[]> {
  return (await all()).filter((q) => !isTrainingTitle(q.title));
}

/** База по обучению — только «Обучение · …», без пациентских цен и расписаний. */
export async function trainingKnowledge(): Promise<QuickReply[]> {
  return (await all()).filter((q) => isTrainingTitle(q.title));
}
