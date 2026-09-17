// ВАЖНО: первым — инициализация Admin SDK и глобальных опций (регион/CPU),
// иначе функции из подмодулей определяются раньше setGlobalOptions.
import "./globals";
import { onRequest, onCall, HttpsError } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { WAZZUP_WEBHOOK_SECRET } from "./wazzup-secrets";

// ── Telegram — прямой транспорт вместо агрегатора Wazzup ──────────────────
// WhatsApp/Wazzup-функции сняты с деплоя и лежат в ./wazzup-archive.ts
// (файл не импортируется). История WhatsApp-переписки в Firestore сохранена.
export { tgWebhook, tgProcessUpdate } from "./telegram/inbound";
export {
  tgSendMessage,
  tgSendMedia,
  tgTyping,
  tgTransfer,
  tgEditMessage,
  tgDeleteMessage,
  tgRequestPhone,
  tgProcessOutbox,
} from "./telegram/outbound";
export { tgSetup, tgFixNames } from "./telegram/setup";

// Вечерняя сводка дня руководству в Telegram (21:00 Астаны).
export { dailyReport } from "./daily-report";

// Догрев «недожатых»: одно напоминание тем, кто интересовался и замолчал.
export { followUp } from "./follow-up";

// Лиды владельца автоматически записываются на менеджера (config/leads.autoOwner).
export { onLeadCreated } from "./lead-owner";

// ── WhatsApp через Wazzup — второй транспорт (вернулся из архива) ─────────
// Отправка менеджера всегда идёт через очередь с «человечной» задержкой
// (config/wazzup.sendDelaySec): в чате видно сразу, в WhatsApp — чуть позже.
export {
  wazzupWebhook,
  mediaContent,
  sendMessage,
  sendMedia,
  editMessage,
  deleteMessage,
  processOutbox,
  onOutboxCreated,
  onMessageMedia,
  onQuickReplyWritten,
  // WABA (подписка оплачена 2026-08-08): выбор канала, шаблоны Meta,
  // 24-часовое окно — настраивается из приложения без передеплоя.
  channelStatus,
  wazzupChannelList,
  wabaTemplates,
  sendWabaTemplate,
  setChannelConfig,
} from "./wazzup-functions";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

/** Проверка деплоя. */
export const ping = onRequest((_req, res) => {
  res.json({ ok: true, service: "vip-crm-functions", ts: new Date().toISOString() });
});

/**
 * Разовая инициализация: делает всех существующих Firebase Auth пользователей
 * админами (создаёт users/{uid}). Работает только если коллекция users пуста.
 * Защита — секрет в ?secret=.
 */
export const bootstrapAdmins = onRequest({ secrets: [WAZZUP_WEBHOOK_SECRET] }, async (req, res) => {
  if ((req.query.secret as string | undefined) !== WAZZUP_WEBHOOK_SECRET.value()) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  const firestore = db();
  const list = await admin.auth().listUsers(100);
  const created: string[] = [];
  const skipped: string[] = [];
  for (const u of list.users) {
    const ref = firestore.collection("users").doc(u.uid);
    const snap = await ref.get();
    if (snap.exists) {
      skipped.push(u.email ?? u.uid);
      continue;
    }
    await ref.set({
      email: u.email ?? "",
      name: u.displayName ?? (u.email ?? ""),
      role: "admin",
      isActive: true,
      createdAt: ts(),
    });
    created.push(u.email ?? u.uid);
  }
  const all = await firestore.collection("users").get();
  const existingDocs = all.docs.map((d) => ({ id: d.id, email: d.get("email"), role: d.get("role") }));
  res.json({ ok: true, created, skipped, usersDocsTotal: all.size, existingDocs });
});

/**
 * Ремонт профилей менеджеров: показывает, у кого из пользователей Firebase Auth
 * пропал документ users/{uid} (после случайного удаления в консоли), и по
 * запросу восстанавливает его. Вход в приложение без такого документа
 * невозможен — правила Firestore не пускают.
 *
 * Список:      GET /repairManagers?secret=<secret>
 * Восстановить: GET /repairManagers?secret=...&email=user2@gmail.com&name=Асель&role=manager
 */
export const repairManagers = onRequest({ secrets: [WAZZUP_WEBHOOK_SECRET] }, async (req, res) => {
  if ((req.query.secret as string | undefined) !== WAZZUP_WEBHOOK_SECRET.value()) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  const firestore = db();
  const email = String(req.query.email ?? "").trim().toLowerCase();

  if (email) {
    try {
      const user = await admin.auth().getUserByEmail(email);
      const name = String(req.query.name ?? "").trim() || (user.displayName ?? email.split("@")[0] ?? "Менеджер");
      const role = String(req.query.role ?? "manager").trim() || "manager";
      await firestore.collection("users").doc(user.uid).set(
        { email, name, role, isActive: true, restoredAt: ts() },
        { merge: true },
      );
      res.json({ ok: true, restored: { uid: user.uid, email, name, role } });
    } catch (e) {
      res.status(404).json({ ok: false, error: String(e instanceof Error ? e.message : e) });
    }
    return;
  }

  // Отчёт: кто есть в Auth и у кого нет профиля + «осиротевшие» профили,
  // у которых пользователь Auth удалён (их правка падает с INTERNAL).
  const list = await admin.auth().listUsers(200);
  const authUids = new Set(list.users.map((u) => u.uid));
  const rows = await Promise.all(
    list.users.map(async (u) => {
      const doc = await firestore.collection("users").doc(u.uid).get();
      const d = doc.data();
      return {
        uid: u.uid,
        email: u.email ?? "",
        hasProfile: doc.exists,
        name: (d?.name as string) ?? "",
        role: (d?.role as string) ?? "",
        isActive: d?.isActive !== false,
      };
    }),
  );

  const profiles = await firestore.collection("users").get();
  const orphans = profiles.docs
    .filter((d) => !authUids.has(d.id))
    .map((d) => ({ uid: d.id, email: (d.data().email as string) ?? "", name: (d.data().name as string) ?? "" }));

  // ?cleanup=1 — пометить профили без пользователя Auth отключёнными.
  // Не удаляем: на эти uid ссылается история сообщений и аналитика.
  if (req.query.cleanup === "1" && orphans.length) {
    const batch = firestore.batch();
    for (const o of orphans) {
      batch.set(
        firestore.collection("users").doc(o.uid),
        { isActive: false, authDeleted: true, updatedAt: ts() },
        { merge: true },
      );
    }
    await batch.commit();
  }

  res.json({
    ok: true,
    total: rows.length,
    broken: rows.filter((r) => !r.hasProfile).length,
    users: rows,
    orphans,
    cleaned: req.query.cleanup === "1" ? orphans.length : 0,
  });
});

/** Создать менеджера (callable, только админ): Firebase Auth + users/{uid}. */
export const createManager = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Требуется вход");
  const caller = await db().collection("users").doc(uid).get();
  const callerRole = caller.data()?.role;
  if (callerRole !== "admin" && callerRole !== "administrator") {
    throw new HttpsError("permission-denied", "Только админ");
  }

  const data = (request.data ?? {}) as { email?: string; name?: string; password?: string; role?: string };
  const email = (data.email ?? "").trim();
  const password = (data.password ?? "").trim();
  const name = (data.name ?? "").trim();
  if (!email || password.length < 6) throw new HttpsError("invalid-argument", "email и пароль (от 6) обязательны");
  const role = ["admin", "manager", "viewer"].includes(data.role ?? "") ? (data.role as string) : "manager";

  const user = await admin.auth().createUser({ email, password, displayName: name || undefined });
  await db().collection("users").doc(user.uid).set({ email, name, role, isActive: true, createdAt: ts() });
  return { ok: true, uid: user.uid };
});

/** Изменить менеджера (callable, только админ): имя/роль/активность/сброс пароля. */
export const updateManager = onCall(async (request) => {
  const callerUid = request.auth?.uid;
  if (!callerUid) throw new HttpsError("unauthenticated", "Требуется вход");
  const caller = await db().collection("users").doc(callerUid).get();
  const cr = caller.data()?.role;
  if (cr !== "admin" && cr !== "administrator") throw new HttpsError("permission-denied", "Только админ");

  const data = (request.data ?? {}) as { uid?: string; name?: string; role?: string; isActive?: boolean; password?: string };
  const uid = (data.uid ?? "").trim();
  if (!uid) throw new HttpsError("invalid-argument", "uid обязателен");
  if (uid === callerUid && data.isActive === false) throw new HttpsError("failed-precondition", "Нельзя отключить самого себя");

  const authUpdate: Record<string, unknown> = {};
  if (data.isActive !== undefined) authUpdate.disabled = !data.isActive;
  if (data.password && data.password.length >= 6) authUpdate.password = data.password;
  if (data.name !== undefined) authUpdate.displayName = data.name;
  if (Object.keys(authUpdate).length > 0) {
    try {
      await admin.auth().updateUser(uid, authUpdate);
    } catch (e) {
      // Пользователя удалили в консоли Firebase — раньше это падало как INTERNAL.
      const code = (e as { code?: string }).code ?? "";
      if (code.includes("user-not-found")) {
        throw new HttpsError(
          "not-found",
          "Этот менеджер удалён из Firebase Auth. Удалите его в списке и создайте заново.",
        );
      }
      throw new HttpsError("internal", String(e instanceof Error ? e.message : e));
    }
  }

  const docUpdate: Record<string, unknown> = { updatedAt: ts() };
  if (data.name !== undefined) docUpdate.name = data.name;
  if (data.role !== undefined && ["admin", "administrator", "manager", "viewer"].includes(data.role)) docUpdate.role = data.role;
  if (data.isActive !== undefined) docUpdate.isActive = data.isActive;
  await db().collection("users").doc(uid).set(docUpdate, { merge: true });

  return { ok: true };
});
