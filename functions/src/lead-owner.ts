/**
 * Автоматическая передача лидов: всё, что заводит один менеджер, сразу
 * записывается на другого.
 *
 * Зачем: владелец (Нурс) сам ведёт часть переписок и заводит лиды, но в
 * зачёт соревнования и в статистику они должны идти менеджеру Тиме
 * (решение владельца 2026-09-06). Раньше это делали вручную через
 * ?action=leadowner каждый день.
 *
 * Правило хранится в config/leads.autoOwner = { from, to, enabled } — его
 * можно выключить или сменить адресата без передеплоя (?action=leadauto).
 * Прежний автор остаётся в createdByPrev, как и при ручной передаче.
 */
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";

const db = () => admin.firestore();

export type AutoOwner = { from: string; to: string; enabled: boolean };

export async function autoOwnerRule(): Promise<AutoOwner | null> {
  const d = (await db().doc("config/leads").get()).data() ?? {};
  const r = d.autoOwner;
  if (!r || typeof r !== "object") return null;
  const from = String((r as Record<string, unknown>).from ?? "").trim();
  const to = String((r as Record<string, unknown>).to ?? "").trim();
  const enabled = (r as Record<string, unknown>).enabled !== false;
  if (!from || !to) return null;
  return { from, to, enabled };
}

export const onLeadCreated = onDocumentCreated("leads/{id}", async (event) => {
  const snap = event.data;
  if (!snap) return;
  const x = snap.data() as Record<string, unknown>;
  const rule = await autoOwnerRule();
  if (!rule || !rule.enabled) return;
  if (String(x.createdBy ?? "") !== rule.from || rule.from === rule.to) return;
  await snap.ref.set(
    {
      createdBy: rule.to,
      createdByPrev: rule.from,
      ownerChangedAt: admin.firestore.FieldValue.serverTimestamp(),
      // Отличаем от ручной передачи: видно, что сработало правило.
      ownerAuto: true,
    },
    { merge: true },
  );
  console.log("lead auto-owner", JSON.stringify({ id: snap.id, leadNumber: x.leadNumber ?? null, from: rule.from, to: rule.to }));
});
