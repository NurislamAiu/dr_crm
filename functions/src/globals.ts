import { setGlobalOptions } from "firebase-functions/v2";
import * as admin from "firebase-admin";

/**
 * Инициализация ДО определения любых функций. Этот модуль импортируется
 * первой строкой index.ts: в CommonJS импорты исполняются по порядку, и
 * только так глобальные опции действуют на функции из подмодулей
 * (telegram/*), чьи определения исполняются при импорте.
 *
 * cpu: "gcf_gen1" — дробный CPU как в 1-м поколении (+ concurrency 1):
 * иначе ~30 функций по 1 vCPU упираются в квоту «total allowable CPU per
 * project per region» и деплой падает на healthcheck. Для нашей нагрузки
 * (4 менеджера, короткие запросы) этого более чем достаточно.
 */
admin.initializeApp();
setGlobalOptions({ region: "europe-west1", maxInstances: 5, cpu: "gcf_gen1", concurrency: 1 });
