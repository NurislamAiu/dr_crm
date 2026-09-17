/**
 * Автоответ «мы недоступны» — на дни, когда отвечать некому (отпуск,
 * праздники). Уходит ТОЛЬКО новым обращениям: тем, кто пишет нам первый раз
 * (тот же момент, когда обычно уходит приветствие/первый автоответ).
 * Существующим клиентам, с которыми уже была переписка, ничего не шлём —
 * это не рассылка, а замена приветствия на время простоя.
 *
 * Включается/выключается переключателем в настройках приложения
 * (config/vacationReply.enabled). Текст редактируется там же.
 */
import * as admin from "firebase-admin";
import { uniquifyText } from "./variate";

const db = () => admin.firestore();

const DEFAULT_TEXT =
  "Добрый день!\n\n" +
  "Извините, с 21 по 23 августа не сможем вам ответить.\n" +
  "Напишите ваш вопрос — менеджер свяжется с вами позже.";

/// Разные первые строки — тот же приём, что и у обычного автоответа
/// WhatsApp (WA_OPENINGS): иначе десятки новых чатов за день получат
/// побайтово одинаковый текст, а это то, за что банят номер.
const OPENINGS = ["Добрый день!", "Здравствуйте!", "Приветствуем!"];

export type VacationCfg = { enabled: boolean; text: string };

let cache: { v: VacationCfg; at: number } | null = null;

export async function vacationCfg(): Promise<VacationCfg> {
  if (cache && Date.now() - cache.at < 60_000) return cache.v;
  let v: VacationCfg = { enabled: false, text: DEFAULT_TEXT };
  try {
    const d = (await db().doc("config/vacationReply").get()).data() ?? {};
    v = {
      enabled: d.enabled === true,
      text: typeof d.text === "string" && d.text.trim().length > 0 ? d.text.trim() : DEFAULT_TEXT,
    };
  } catch {
    /* нет конфига — считаем выключенным */
  }
  cache = { v, at: Date.now() };
  return v;
}

/**
 * Текст для конкретного чата: своя первая строка (если пользователь не
 * поменял текст на свой — тогда шлём как есть, не разбивая) + невидимая
 * уникализация, как у остальных авто-сообщений.
 */
export function vacationText(cfg: VacationCfg, chatId: string): string {
  let base = cfg.text;
  if (base === DEFAULT_TEXT) {
    const opening = OPENINGS[Math.abs(hash(chatId)) % OPENINGS.length];
    base = base.replace(/^[^\n]*/, opening!);
  }
  return uniquifyText(base, chatId);
}

function hash(s: string): number {
  let h = 7;
  for (const c of s) h = (h * 31 + c.charCodeAt(0)) | 0;
  return h;
}
