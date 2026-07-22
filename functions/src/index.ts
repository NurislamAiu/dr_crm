import { onRequest } from "firebase-functions/v2/https";
import { setGlobalOptions } from "firebase-functions/v2";
import * as admin from "firebase-admin";

admin.initializeApp();

// Регион ближе к клиенту/Wazzup; ограничиваем экземпляры (защита от «дорогих»
// всплесков — важно для контроля счёта на Blaze).
setGlobalOptions({ region: "europe-west1", maxInstances: 5 });

/**
 * Фаза 0 — проверка, что деплой Cloud Functions работает.
 * Логику вебхука Wazzup, отправки и медиа добавим в Фазе 1 (прод на Mac пока
 * не трогаем; вебхук Wazzup всё ещё указывает на Mac).
 */
export const ping = onRequest((_req, res) => {
  res.json({ ok: true, service: "vip-crm-functions", ts: new Date().toISOString() });
});
