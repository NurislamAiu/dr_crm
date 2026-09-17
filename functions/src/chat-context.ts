/**
 * Переписка из Firestore в формате, который понимает Claude.
 *
 * Общее для всех ботов-автоответчиков (пациенты, обучение): без истории
 * модель отвечает так, будто чат начался с нуля, — а бот, который «забыл»
 * предыдущее сообщение клиента, однажды написал живому человеку, что чата с
 * ним не существует. Поэтому историю собираем всегда и одинаково.
 */
import * as admin from "firebase-admin";
import Anthropic from "@anthropic-ai/sdk";

/** «8 747…» — внутренний формат ввода, в базе телефоны хранятся с «7». */
export function normalizePhone(v: unknown): string {
  let d = String(v ?? "").replace(/\D/g, "");
  if (d.length === 11 && d.startsWith("8")) d = `7${d.slice(1)}`;
  return d;
}

/**
 * Короткое текстовое представление сообщения для истории. Реальные фото/PDF/
 * аудио сюда не грузим (дорого и не нужно для КАЖДОГО старого сообщения) —
 * модель просто видит, что там было вложение; полное содержимое получает
 * только последнее сообщение, если вызывающий код его подставит.
 */
export function historyText(m: FirebaseFirestore.DocumentData): string {
  if (m.isDeleted === true) return "[сообщение удалено]";
  const text = typeof m.text === "string" ? m.text.trim() : "";
  if (text) return text.slice(0, 500);
  const type = String(m.type ?? "");
  if (type === "image") return "[фото]";
  if (type === "audio") return "[голосовое сообщение]";
  if (type === "document") return `[файл${m.fileName ? `: ${m.fileName}` : ""}]`;
  return "[сообщение без текста]";
}

/**
 * Сообщения (по УБЫВАНИЮ времени, как отдаёт Firestore) → ходы диалога по
 * возрастанию. Claude ждёт чередования user/assistant, поэтому две реплики
 * одной стороны подряд склеиваются в один ход, а начальные ответы клиники
 * отбрасываются — история обязана начинаться с клиента.
 */
export function toAlternating(msgsDesc: FirebaseFirestore.DocumentData[]): Anthropic.MessageParam[] {
  const history: Anthropic.MessageParam[] = [];
  for (const m of [...msgsDesc].reverse()) {
    if (m.isInternal === true || m.type === "call" || m.isDeleted === true) continue;
    const role: "user" | "assistant" = m.direction === "inbound" ? "user" : "assistant";
    const content = historyText(m);
    const prev = history[history.length - 1];
    if (prev && prev.role === role && typeof prev.content === "string") {
      prev.content = `${prev.content}\n${content}`;
    } else {
      history.push({ role, content });
    }
  }
  while (history.length > 0 && history[0]!.role === "assistant") history.shift();
  return history;
}

/** Последние сообщения чата, свежие первыми. */
export async function recentMessages(chatId: string, limit: number): Promise<FirebaseFirestore.DocumentData[]> {
  const snap = await admin
    .firestore()
    .collection("messages")
    .where("conversationId", "==", chatId)
    .orderBy("createdAt", "desc")
    .limit(limit)
    .get();
  return snap.docs.map((d) => d.data());
}
