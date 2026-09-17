import { defineSecret } from "firebase-functions/params";

/**
 * Секреты Telegram (Secret Manager, задаются через
 * `firebase functions:secrets:set ...`). Токен бота живёт только на сервере —
 * во Flutter он не попадает ни при каких условиях.
 */
export const TELEGRAM_BOT_TOKEN = defineSecret("TELEGRAM_BOT_TOKEN");

/**
 * Секрет вебхука: передаётся в setWebhook как secret_token, Telegram шлёт его
 * обратно в заголовке X-Telegram-Bot-Api-Secret-Token. Допустимые символы:
 * A-Z a-z 0-9 _ - (до 256).
 */
export const TELEGRAM_WEBHOOK_SECRET = defineSecret("TELEGRAM_WEBHOOK_SECRET");
