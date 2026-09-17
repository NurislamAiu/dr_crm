import { defineSecret } from "firebase-functions/params";

/**
 * Секреты Wazzup — в одном месте: defineSecret с одним именем нельзя вызывать
 * в двух модулях. Используются wazzup-functions.ts (транспорт WhatsApp) и
 * index.ts (?secret= у админ-утилит bootstrapAdmins/repairManagers).
 */
export const WAZZUP_WEBHOOK_SECRET = defineSecret("WAZZUP_WEBHOOK_SECRET");
export const WAZZUP_API_KEY = defineSecret("WAZZUP_API_KEY");
export const WAZZUP_CHANNEL_ID = defineSecret("WAZZUP_CHANNEL_ID");
