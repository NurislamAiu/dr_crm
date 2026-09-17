import { onRequest, onCall, HttpsError } from "firebase-functions/v2/https";
import { randomUUID } from "crypto";
import * as admin from "firebase-admin";
import { TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET } from "./secrets";
import { tgCall, tgSendTextApi } from "./api";
import { exactFingerprint, makeVariants, uniquifyText } from "../variate";
import { enqueue } from "../limits";
import { fingerprint } from "../risk";
import { publicMediaUrl, toWhatsAppAudio } from "../audio";
import { ANTHROPIC_API_KEY, aiTestReply } from "../ai-reply";
import { trainingBacklog, trainingTestReply } from "../training-reply";
import { detectPaymentIntent } from "../payment-alert";
import { computeConversionStats, computeManagerStats, leadPhoneIndex } from "../conversion-stats";
import { telegramAutoMessagesOn, whatsappAutoMessagesOn } from "../auto-messages";
import { buildDailyReport, reportDayStartMs, reportRecipients, sendReport } from "../daily-report";
import { followCandidates, runFollowUps } from "../follow-up";
import { detectTopic, isOwnTabTopic, normalizeAnyScript, normalizeTopicText, topicRules } from "../topics";
import { WAZZUP_API_KEY } from "../wazzup-secrets";
import { REGION_HOST, TG_DEFAULT_TEXTS, TG_REGION, countryByPhone, extractPhoneFromText, tgTexts } from "./common";

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();

/**
 * Ремонт Telegram-чатов (идемпотентный, можно запускать сколько угодно):
 * 1) у кого номер уже есть — именем чата становится номер;
 * 2) у кого номера нет — ищется ПЕРВЫЙ номер, написанный клиентом текстом
 *    в истории переписки, и записывается в карточку (phoneSource=typed).
 */
async function runFixNames(): Promise<{ scanned: number; fixed: { id: string; name: string }[] }> {
  const firestore = db();
  const snap = await firestore
    .collection("contacts")
    .where(admin.firestore.FieldPath.documentId(), ">=", "tg_")
    .where(admin.firestore.FieldPath.documentId(), "<", "tg`")
    .limit(500)
    .get();
  const fixed: { id: string; name: string }[] = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    const phone = typeof d.phone === "string" && d.phone.length > 0 ? d.phone : null;
    const current = String(d.name ?? "");

    // Телефона в карточке нет — ищем первый номер в истории переписки.
    if (!phone) {
      const msgs = await firestore
        .collection("messages")
        .where("conversationId", "==", doc.id)
        .orderBy("createdAt", "desc")
        .limit(500)
        .get();
      let typed: string | null = null;
      for (let i = msgs.docs.length - 1; i >= 0; i--) {
        const md = msgs.docs[i];
        if (!md) continue;
        const x = md.data();
        if (x.direction !== "inbound") continue;
        const t = typeof x.text === "string" ? x.text : "";
        if (!t || t.startsWith("/start")) continue;
        const p = extractPhoneFromText(t);
        if (p) {
          typed = p;
          break;
        }
      }
      if (typed) {
        const name = `+${typed}`;
        await doc.ref.set(
          { phone: typed, country: countryByPhone(typed), phoneSource: "typed", name, updatedAt: ts() },
          { merge: true },
        );
        await firestore.collection("conversations").doc(doc.id).set({ phone: typed, name, updatedAt: ts() }, { merge: true });
        fixed.push({ id: doc.id, name });
      }
      continue;
    }

    const name = `+${phone}`;
    if (name === current) continue;
    await doc.ref.set({ name, updatedAt: ts() }, { merge: true });
    await firestore.collection("conversations").doc(doc.id).set({ name, updatedAt: ts() }, { merge: true });
    fixed.push({ id: doc.id, name });
  }
  return { scanned: snap.size, fixed };
}

/**
 * Кнопка «Обновить номера из переписки» в настройках приложения
 * (callable, только админ) — тот же ремонт, что и tgSetup?action=fixnames.
 */
export const tgFixNames = onCall({ region: TG_REGION }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Требуется вход");
  const role = String((await db().collection("users").doc(uid).get()).data()?.role ?? "");
  if (role !== "admin" && role !== "administrator") throw new HttpsError("permission-denied", "Только админ");
  const result = await runFixNames();
  return { ok: true, scanned: result.scanned, fixedCount: result.fixed.length, fixed: result.fixed };
});

/**
 * Настройка и диагностика вебхука Telegram (по секрету, как opsStatus).
 *
 * Диагностика: GET /tgSetup?secret=<TELEGRAM_WEBHOOK_SECRET>
 * Подписка:    GET /tgSetup?secret=...&action=set
 * Отписка:     GET /tgSetup?secret=...&action=delete
 */
export const tgSetup = onRequest(
  // 540с — запас для ?action=convstats: до 700 точечных запросов к messages.
  { region: TG_REGION, secrets: [TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET, WAZZUP_API_KEY, ANTHROPIC_API_KEY], timeoutSeconds: 540 },
  async (req, res) => {
  if ((req.query.secret as string | undefined) !== TELEGRAM_WEBHOOK_SECRET.value()) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  const token = TELEGRAM_BOT_TOKEN.value();
  const action = String(req.query.action ?? "");

  try {
    if (action === "set") {
      const result = await tgCall<unknown>(token, "setWebhook", {
        url: `${REGION_HOST}/tgWebhook`,
        secret_token: TELEGRAM_WEBHOOK_SECRET.value(),
        // message/edited_message/callback_query — рабочий набор;
        // business_* — задел под личный аккаунт (Telegram Business);
        // my_chat_member — узнаём, что клиент заблокировал бота.
        allowed_updates: [
          "message",
          "edited_message",
          "callback_query",
          "business_message",
          "edited_business_message",
          "deleted_business_messages",
          "my_chat_member",
        ],
      });
      // Сид текстов бота — если их ещё нет (правятся в config/telegram).
      const cfgRef = db().doc("config/telegram");
      if (!(await cfgRef.get()).exists) {
        await cfgRef.set({ ...TG_DEFAULT_TEXTS, updatedAt: ts() });
      }
      res.json({ ok: true, webhook: result, url: `${REGION_HOST}/tgWebhook` });
      return;
    }

    if (action === "delete") {
      res.json({ ok: true, result: await tgCall<unknown>(token, "deleteWebhook", {}) });
      return;
    }

    // Ремонт имён существующих Telegram-чатов: у кого есть номер — именем
    // становится номер; номера, написанные текстом в истории, подтягиваются.
    if (action === "fixnames") {
      res.json({ ok: true, ...(await runFixNames()) });
      return;
    }

    // Здоровье приложения: профили менеджеров (вход без users/{uid}
    // невозможен — правила Firestore не пускают, экран мигает ретраями),
    // правило «один менеджер», активная сессия, presence.
    if (action === "health") {
      const firestore = db();
      const authList = await admin.auth().listUsers(100);
      const managers = await Promise.all(
        authList.users.map(async (u) => {
          const doc = await firestore.collection("users").doc(u.uid).get();
          const d = doc.data();
          return {
            uid: u.uid,
            email: u.email ?? "",
            hasProfile: doc.exists,
            name: (d?.name as string) ?? "",
            role: (d?.role as string) ?? "",
            isActive: d?.isActive !== false,
            authDisabled: u.disabled,
            lastSignIn: u.metadata.lastSignInTime ?? null,
          };
        }),
      );
      const access = (await firestore.doc("config/access").get()).data() ?? {};
      const session = (await firestore.doc("sessions/current").get()).data() ?? {};
      const presence = await firestore.collection("presence").get();
      res.json({
        ok: true,
        managers,
        broken: managers.filter((m) => !m.hasProfile || !m.isActive || m.authDisabled),
        singleSessionEnabled: access.singleSession !== false,
        activeSession: { uid: session.uid ?? null, name: session.name ?? null },
        presence: presence.docs.map((p) => ({
          uid: p.id,
          online: p.data().online === true,
          name: p.data().name ?? "",
        })),
      });
      return;
    }

    // Что бот отправляет прямо сейчас (config/telegram + значения из кода,
    // если поле не задано). ?action=texts
    if (action === "texts") {
      const live = await tgTexts();
      const stored = (await db().doc("config/telegram").get()).data() ?? {};
      res.json({
        ok: true,
        live,
        storedKeys: Object.keys(stored).filter((k) => k !== "updatedAt"),
      });
      return;
    }

    // Обновить тексты бота в config/telegram значениями по умолчанию из кода
    // (правки greeting/askPhone/foreignInfo применяются без ручной правки в
    // консоли Firestore). ?action=synctexts[&only=greeting]
    if (action === "synctexts") {
      const only = String(req.query.only ?? "").trim();
      const patch: Record<string, unknown> = only
        ? { [only]: (TG_DEFAULT_TEXTS as unknown as Record<string, string>)[only] }
        : { ...TG_DEFAULT_TEXTS };
      if (only && patch[only] === undefined) {
        res.status(400).json({ ok: false, error: `Нет такого текста: ${only}` });
        return;
      }
      await db().doc("config/telegram").set({ ...patch, updatedAt: ts() }, { merge: true });
      res.json({ ok: true, updated: Object.keys(patch), values: patch });
      return;
    }

    // Выключить/включить правило «один менеджер в системе» удалённо:
    // ?action=singlesession&value=off|on
    if (action === "singlesession") {
      const value = String(req.query.value ?? "") !== "off";
      await db().doc("config/access").set(
        { singleSession: value, updatedAt: ts() },
        { merge: true },
      );
      res.json({ ok: true, singleSession: value });
      return;
    }

    // Чистка мусорных workSessions после шторма lifecycle на Samsung:
    // удаляем сессии короче 2 минут за последние 3 дня (реальные смены
    // менеджеров длиннее и не трогаются). ?action=cleansessions
    if (action === "cleansessions") {
      const firestore = db();
      const since = admin.firestore.Timestamp.fromMillis(Date.now() - 3 * 86400_000);
      let scanned = 0;
      let deleted = 0;
      let kept = 0;
      const perUser: Record<string, number> = {};
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      for (let page = 0; page < 60; page++) {
        let q = firestore
          .collection("workSessions")
          .where("startAt", ">=", since)
          .orderBy("startAt", "asc")
          .limit(400);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        scanned += snap.size;
        const batch = firestore.batch();
        let inBatch = 0;
        for (const d of snap.docs) {
          const x = d.data();
          const startMs = (x.startAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          const endMs = ((x.endAt ?? x.lastActiveAt) as admin.firestore.Timestamp | undefined)?.toMillis() ?? startMs;
          if ((endMs - startMs) / 1000 < 120) {
            batch.delete(d.ref);
            inBatch++;
            deleted++;
            const uid = String(x.uid ?? "?");
            perUser[uid] = (perUser[uid] ?? 0) + 1;
          } else {
            kept++;
          }
        }
        if (inBatch > 0) await batch.commit();
        if (snap.size < 400) break;
      }
      const users = await firestore.collection("users").get();
      const names = new Map(users.docs.map((d) => [d.id, String(d.data().name ?? "")]));
      res.json({
        ok: true,
        scanned,
        deleted,
        kept,
        perUser: Object.entries(perUser).map(([uid, n]) => ({ uid, name: names.get(uid) ?? "", deleted: n })),
      });
      return;
    }

    // Включить/выключить автоответ WhatsApp: ?action=autoreply_on|autoreply_off
    if (action === "autoreply_on" || action === "autoreply_off") {
      const on = action === "autoreply_on";
      await db().doc("config/waAutoReply").set({ enabled: on, updatedAt: ts() }, { merge: true });
      res.json({ ok: true, enabled: on });
      return;
    }

    // Пометить ВСЕ существующие WhatsApp-чаты как «автоответ уже не нужен».
    // Страховка: после этого автоответ физически может уйти только новому
    // чату, которого сейчас в базе нет. ?action=autoreply_seed
    if (action === "autoreply_seed") {
      const firestore = db();
      let marked = 0;
      let scanned = 0;
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      for (let page = 0; page < 40; page++) {
        let q = firestore.collection("conversations").orderBy(admin.firestore.FieldPath.documentId()).limit(300);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        const batch = firestore.batch();
        let inBatch = 0;
        for (const d of snap.docs) {
          scanned++;
          if (d.id.startsWith("tg_")) continue; // Telegram живёт своей логикой
          if (d.data().waAutoReplyAt) continue;
          batch.set(d.ref, { waAutoReplyAt: ts(), waAutoReplySkip: "существующий чат" }, { merge: true });
          inBatch++;
          marked++;
        }
        if (inBatch > 0) await batch.commit();
        if (snap.size < 300) break;
      }
      res.json({ ok: true, scanned, помечено: marked });
      return;
    }

    // Сколько раз за сутки ушёл автоответ Wazzup (и сколько всего исходящих
    // без нашего crmMessageId, т.е. отправленных мимо CRM). ?action=autoreply
    if (action === "autoreply") {
      const firestore = db();
      const hours = Math.min(Number(req.query.hours ?? 24) || 24, 72);
      const since = admin.firestore.Timestamp.fromMillis(Date.now() - hours * 3600_000);
      const snap = await firestore
        .collection("messages")
        .where("createdAt", ">=", since)
        .orderBy("createdAt", "desc")
        .limit(8000)
        .get();
      const needle = "Спасибо, что написали";
      let ourAuto = 0;
      const ourAutoChats: string[] = [];
      let auto = 0;
      let outMimoCrm = 0;
      let outTotal = 0;
      const chats = new Set<string>();
      for (const d of snap.docs) {
        const x = d.data();
        const cid = String(x.conversationId ?? "");
        if (!cid || cid.startsWith("tg_") || x.direction !== "outbound") continue;
        outTotal++;
        if (!x.crmMessageId) outMimoCrm++;
        if (String(x.authorId ?? "") === "auto") {
          ourAuto++;
          if (ourAutoChats.length < 200) ourAutoChats.push(cid);
        }
        if (String(x.text ?? "").includes(needle)) {
          auto++;
          chats.add(cid);
        }
      }
      res.json({
        ok: true,
        hours,
        scanned: snap.size,
        исходящихВсего: outTotal,
        мимоCRM: outMimoCrm,
        автоответовWazzup: auto,
        уникальныхЧатовСАвтоответомWazzup: chats.size,
        автоответовНашейCRM: ourAuto,
        уникальныхЧатовНашейCRM: new Set(ourAutoChats).size,
        // Проверка «ушло только новым»: у каждого чата смотрим, когда там
        // появилось первое сообщение вообще.
        проверкаНовизны: await (async () => {
          const uniq = [...new Set(ourAutoChats)].slice(0, 40);
          const rows: { chat: string; перваяЗапись: string; возрастЧатаМин: number }[] = [];
          for (const cid of uniq) {
            const f = await firestore
              .collection("messages")
              .where("conversationId", "==", cid)
              .orderBy("createdAt", "asc")
              .limit(1)
              .get();
            const at = (f.docs[0]?.data()?.createdAt as admin.firestore.Timestamp | undefined)?.toDate();
            rows.push({
              chat: cid,
              перваяЗапись: at?.toISOString() ?? "—",
              возрастЧатаМин: at ? Math.round((Date.now() - at.getTime()) / 60000) : -1,
            });
          }
          return rows;
        })(),
      });
      return;
    }

    // Настройки WABA и факт использования шаблонов нашей CRM. ?action=wabacfg
    if (action === "wabacfg") {
      const firestore = db();
      const waba = (await firestore.doc("config/waba").get()).data() ?? {};
      const channel = (await firestore.doc("config/channel").get()).data() ?? {};
      const since = admin.firestore.Timestamp.fromMillis(Date.now() - 30 * 86400_000);
      const tpl = await firestore
        .collection("messages")
        .where("isTemplate", "==", true)
        .limit(50)
        .get();
      const openers = await firestore
        .collection("conversations")
        .where("lastOpenerAt", ">=", since)
        .limit(50)
        .get();
      res.json({
        ok: true,
        шаблонПриглашения: waba.openerTemplateId ? String(waba.openerTemplateId) : "НЕ ВЫБРАН",
        openerCooldownHours: waba.openerCooldownHours ?? null,
        каналИзНастроек: channel.channelId ?? "из секрета",
        шаблоновОтправленоНашейCRM: tpl.size,
        чатовСПриглашениемЗа30дней: openers.size,
      });
      return;
    }

    // Документы одного диалога: что реально лежит в базе. ?action=conv&id=tg_1
    if (action === "conv") {
      const firestore = db();
      const id = String(req.query.id ?? "").trim();
      if (!id) {
        res.status(400).json({ ok: false, error: "нужен параметр id" });
        return;
      }
      const conv = (await firestore.doc(`conversations/${id}`).get()).data() ?? null;
      const contact = (await firestore.doc(`contacts/${id}`).get()).data() ?? null;
      const lastAt = (conv?.lastMessageAt as admin.firestore.Timestamp | undefined)?.toDate() ?? null;
      // Сколько диалогов свежее этого — приложение грузит только 500 верхних.
      let newer = 0;
      if (lastAt) {
        const c = await firestore
          .collection("conversations")
          .where("lastMessageAt", ">", admin.firestore.Timestamp.fromDate(lastAt))
          .count()
          .get();
        newer = c.data().count ?? 0;
      }
      res.json({
        ok: true,
        conversation: conv
          ? {
              name: conv.name,
              phone: conv.phone ?? null,
              chatType: conv.chatType ?? null,
              lastMessageAt: lastAt?.toISOString() ?? null,
              responsibleId: conv.responsibleId ?? null,
            }
          : null,
        contact: contact
          ? { name: contact.name, phone: contact.phone ?? null, username: contact.username ?? null, country: contact.country ?? null }
          : null,
        диалоговСвежее: newer,
        попадаетВПервые500: newer < 500,
      });
      return;
    }

    // Весь документ диалога как есть — для отладки полей, которых нет в
    // ?action=conv (topic, aiSuggestion, wantsAppointmentAt…). ?action=rawconv&id=...
    if (action === "rawconv") {
      const id = String(req.query.id ?? "").trim();
      if (!id) {
        res.status(400).json({ ok: false, error: "нужен параметр id" });
        return;
      }
      const raw = (await db().doc(`conversations/${id}`).get()).data() ?? null;
      const out: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(raw ?? {})) {
        out[k] = v instanceof admin.firestore.Timestamp ? v.toDate().toISOString() : v;
      }
      res.json({ ok: true, conversation: out });
      return;
    }

    // Снять тему (topic/topicLocked) с чата — например, тестовый номер
    // случайно закрепился как «обучение» и из-за этого перестал попадать
    // в обычные автоматические сценарии. ?action=cleartopic&id=...
    if (action === "cleartopic") {
      const id = String(req.query.id ?? "").trim();
      if (!id) {
        res.status(400).json({ ok: false, error: "нужен параметр id" });
        return;
      }
      await db().doc(`conversations/${id}`).set(
        { topic: admin.firestore.FieldValue.delete(), topicLocked: admin.firestore.FieldValue.delete(), updatedAt: ts() },
        { merge: true },
      );
      res.json({ ok: true });
      return;
    }

    // Закрепить тему за чатом руками: ?action=settopic&id=...&topic=training
    // (training | supplements). topicLocked — чтобы ключевые слова входящих
    // её потом не перебили. Снимается через cleartopic.
    if (action === "settopic") {
      const id = String(req.query.id ?? "").trim();
      const topic = String(req.query.topic ?? "").trim();
      if (!id || !["training", "supplements", "call"].includes(topic)) {
        res.status(400).json({ ok: false, error: "нужны id и topic=training|supplements|call" });
        return;
      }
      await db().doc(`conversations/${id}`).set({ topic, topicLocked: true, updatedAt: ts() }, { merge: true });
      res.json({ ok: true, чат: id, тема: topic });
      return;
    }

    // Через какой канал Wazzup идут свежие чаты (QR или WABA). ?action=chanuse
    if (action === "chanuse") {
      const firestore = db();
      const snap = await firestore
        .collection("conversations")
        .orderBy("lastMessageAt", "desc")
        .limit(300)
        .get();
      const byCh = new Map<string, { chats: number; last: string }>();
      for (const d of snap.docs) {
        const x = d.data();
        if (String(d.id).startsWith("tg_")) continue;
        const ch = String(x.channelId ?? "—");
        const at = (x.lastMessageAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? "";
        const cur = byCh.get(ch) ?? { chats: 0, last: at };
        cur.chats++;
        if (at > cur.last) cur.last = at;
        byCh.set(ch, cur);
      }
      res.json({
        ok: true,
        wabaChannelId: "b4418ca2-def6-458e-a142-d3483ac762c5",
        каналы: [...byCh.entries()].map(([channelId, v]) => ({ channelId, ...v })),
      });
      return;
    }

    // Сколько переписок мы НАЧАЛИ по правилам Meta: исходящее, перед которым
    // не было входящего за последние 24 часа. Именно это тратит лимит 250.
    // ?action=biz24[&hours=24]
    if (action === "biz24") {
      const firestore = db();
      const hours = Math.min(Number(req.query.hours ?? 24) || 24, 72);
      // Берём с запасом назад, чтобы видеть входящие ДО окна.
      // skip=24 → окно «вчера» (от 48 до 24 часов назад).
      const skip = Math.min(Number(req.query.skip ?? 0) || 0, 168);
      const windowEnd = Date.now() - skip * 3600_000;
      const since = admin.firestore.Timestamp.fromMillis(windowEnd - (hours + 48) * 3600_000);
      const until = admin.firestore.Timestamp.fromMillis(windowEnd);

      // Постранично: при 2500 сообщениях в сутки один limit не покрывает
      // нужный отрезок и даёт ложные «начатые нами».
      const byChat = new Map<string, { at: number; dir: string; crm: boolean; author: string; text: string; id: string }[]>();
      let scannedTotal = 0;
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      for (let page = 0; page < 12; page++) {
        let q = firestore
          .collection("messages")
          .where("createdAt", ">=", since)
          .where("createdAt", "<=", until)
          .orderBy("createdAt", "asc")
          .limit(3000);
        if (cursor) q = q.startAfter(cursor);
        const pageSnap = await q.get();
        if (pageSnap.empty) break;
        cursor = pageSnap.docs[pageSnap.docs.length - 1] ?? null;
        scannedTotal += pageSnap.size;
        for (const d of pageSnap.docs) {
          const x = d.data();
          const cid = String(x.conversationId ?? "");
          if (!cid || cid.startsWith("tg_")) continue;
          const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          (byChat.get(cid) ?? byChat.set(cid, []).get(cid)!).push({
            at,
            dir: String(x.direction ?? ""),
            crm: Boolean(x.crmMessageId),
            author: String(x.authorId ?? x.authorName ?? "—"),
            text: String(x.text ?? `[${x.type}]`).slice(0, 40),
            id: d.id,
          });
        }
        if (pageSnap.size < 3000) break;
      }
      const snap = { size: scannedTotal };

      const windowStart = windowEnd - hours * 3600_000;
      const cold: { chat: string; at: string; crm: boolean; author: string; text: string }[] = [];
      for (const [cid, list] of byChat) {
        list.sort((a, b) => a.at - b.at);
        let lastIn = 0;
        let counted = false; // одна переписка на чат за окно
        for (const m of list) {
          if (m.dir === "inbound") {
            lastIn = m.at;
            continue;
          }
          if (m.at < windowStart || m.at > windowEnd || counted) continue;
          // Окно открыто, если клиент писал в последние 24 часа ДО отправки.
          if (m.at - lastIn < 24 * 3600_000) continue;
          counted = true;
          cold.push({
            chat: cid,
            at: new Date(m.at).toISOString(),
            crm: m.crm,
            author: m.author,
            text: m.text,
          });
        }
      }
      res.json({
        ok: true,
        hours,
        scanned: snap.size,
        chats: byChat.size,
        начатыхНами: cold.length,
        черезНашуCRM: cold.filter((c) => c.crm).length,
        мимоCRM: cold.filter((c) => !c.crm).length,
        примеры: cold.slice(0, 12),
      });
      return;
    }

    // Сводка по WhatsApp за N дней: сколько исходящих, в скольких чатах и
    // сколько переписок начали МЫ (первое сообщение в чате — наше).
    // ?action=wastats[&days=30]
    if (action === "wastats") {
      const firestore = db();
      const days = Math.min(Number(req.query.days ?? 30) || 30, 60);
      const since = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86400_000);
      const snap = await firestore
        .collection("messages")
        .where("createdAt", ">=", since)
        .orderBy("createdAt", "asc")
        .limit(5000)
        .get();

      const byChat = new Map<string, { firstDir: string; out: number; inb: number; firstAt: string }>();
      let outTotal = 0;
      for (const d of snap.docs) {
        const x = d.data();
        const cid = String(x.conversationId ?? "");
        if (!cid || cid.startsWith("tg_")) continue; // только WhatsApp
        const dir = String(x.direction ?? "");
        const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? "";
        const cur = byChat.get(cid) ?? { firstDir: dir, out: 0, inb: 0, firstAt: at };
        if (dir === "outbound") {
          cur.out++;
          outTotal++;
        } else cur.inb++;
        byChat.set(cid, cur);
      }
      const started = [...byChat.values()].filter((c) => c.firstDir === "outbound");
      res.json({
        ok: true,
        days,
        scanned: snap.size,
        whatsappChats: byChat.size,
        outboundMessages: outTotal,
        начатыхНами: started.length,
        первыеПоВремени: started.slice(0, 5).map((c) => c.firstAt),
      });
      return;
    }

    // Чистка дублей от эха Wazzup: наш документ (с crmMessageId) остаётся и
    // забирает статус и внешний id, лишний удаляется.
    // ?action=dedupe[&hours=24][&dry=1]
    if (action === "dedupe") {
      const firestore = db();
      const dry = req.query.dry === "1";
      const hours = Math.min(Number(req.query.hours ?? 24) || 24, 168);
      const since = admin.firestore.Timestamp.fromMillis(Date.now() - hours * 3600_000);
      const snap = await firestore
        .collection("messages")
        .where("createdAt", ">=", since)
        .orderBy("createdAt", "asc")
        .limit(3000)
        .get();

      const norm = (s: string) => s.replace(/\s+/g, " ").trim();
      const byChat = new Map<string, FirebaseFirestore.QueryDocumentSnapshot[]>();
      for (const d of snap.docs) {
        const cid = String(d.data().conversationId ?? "");
        if (!cid) continue;
        (byChat.get(cid) ?? byChat.set(cid, []).get(cid)!).push(d);
      }

      const pairs: { echo: FirebaseFirestore.QueryDocumentSnapshot; twin: FirebaseFirestore.QueryDocumentSnapshot }[] = [];
      for (const docs of byChat.values()) {
        const out = docs.filter((d) => d.data().direction === "outbound");
        const ours = out.filter((d) => d.data().crmMessageId);
        const usedTwin = new Set<string>();
        for (const e of out) {
          if (e.data().crmMessageId) continue; // наш документ, не эхо
          const et = norm(String(e.data().text ?? ""));
          const ems = (e.data().createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          const twin = ours.find((o) => {
            if (usedTwin.has(o.id)) return false;
            const oms = (o.data().createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
            if (Math.abs(oms - ems) > 5 * 60000) return false;
            return et.length > 0
              ? norm(String(o.data().text ?? "")) === et
              : String(o.data().type ?? "") === String(e.data().type ?? "");
          });
          if (twin) {
            usedTwin.add(twin.id);
            pairs.push({ echo: e, twin });
          }
        }
      }

      if (!dry) {
        for (const { echo, twin } of pairs) {
          const e = echo.data();
          const t = twin.data();
          const patch: Record<string, unknown> = { echoMessageId: echo.id };
          if (!t.externalMessageId && e.externalMessageId) patch.externalMessageId = e.externalMessageId;
          // Статус из эха точнее: там уже delivered/read.
          if (["delivered", "read"].includes(String(e.status ?? ""))) patch.status = e.status;
          await twin.ref.set(patch, { merge: true });
          await echo.ref.delete();
        }
      }

      res.json({
        ok: true,
        dry,
        hours,
        scanned: snap.size,
        duplicates: pairs.length,
        deleted: dry ? 0 : pairs.length,
        sample: pairs.slice(0, 10).map((p) => ({
          chat: p.echo.data().conversationId,
          удаляем: p.echo.id,
          оставляем: p.twin.id,
          text: String(p.echo.data().text ?? `[${p.echo.data().type}]`).slice(0, 50),
        })),
      });
      return;
    }

    // Последние сообщения чата — чтобы отличить настоящий дубль в базе от
    // артефакта интерфейса. ?action=lastmsgs[&chat=<id>][&limit=15]
    // Сменить автора исходящего сообщения (кто «отвечал» в переписке).
    // Прежний автор сохраняется в authorIdPrev. Подпись последнего ответа в
    // списке чатов меняется, только если она указывала на того же автора.
    //   ?action=msgauthor&id=<messageId>&to=Гульсана[&dry=1]
    if (action === "msgauthor") {
      const firestore = db();
      const id = String(req.query.id ?? "").trim();
      const users = await firestore.collection("users").limit(100).get();
      const nameOf = new Map(users.docs.map((d) => [d.id, String(d.data().name ?? "").trim() || d.id]));
      const toQ = String(req.query.to ?? "").trim().toLowerCase();
      let toUid: string | null = null;
      for (const [uid, name] of nameOf) if (uid === toQ || name.toLowerCase() === toQ) toUid = uid;
      if (!id || !toUid) {
        res.status(400).json({ ok: false, error: "нужны id сообщения и to (имя или uid)", естьМенеджеры: [...nameOf.values()] });
        return;
      }
      const ref = firestore.collection("messages").doc(id);
      const snap = await ref.get();
      if (!snap.exists) {
        res.status(404).json({ ok: false, error: "сообщение не найдено" });
        return;
      }
      const x = snap.data()!;
      const prev = String(x.authorId ?? "");
      const chat = String(x.conversationId ?? "");
      const conv = chat ? (await firestore.doc(`conversations/${chat}`).get()).data() ?? {} : {};
      const convToo = chat !== "" && String(conv.lastAuthorId ?? "") === prev && prev !== "";
      if (String(req.query.dry ?? "") !== "1") {
        await ref.set({ authorId: toUid, authorIdPrev: prev || null, authorChangedAt: ts() }, { merge: true });
        if (convToo) await firestore.doc(`conversations/${chat}`).set({ lastAuthorId: toUid, lastAuthorName: null }, { merge: true });
      }
      res.json({
        ok: true,
        сообщение: id,
        чат: chat,
        текст: String(x.text ?? "").slice(0, 60),
        было: nameOf.get(prev) ?? (prev || "не указан"),
        стало: nameOf.get(toUid),
        подписьВСпискеЧатов: convToo ? "тоже изменена" : "не трогали (последний ответ другого автора)",
      });
      return;
    }
    // Кто писал в заданную минуту: ?action=msgsat&at=2026-09-09T10:55&min=5
    //   at  — время по Астане, min — ± минут вокруг (по умолчанию 5),
    //   dir=inbound|outbound|all (по умолчанию inbound). Номер для Telegram
    //   берётся из карточки чата.
    if (action === "msgsat") {
      const firestore = db();
      const at = String(req.query.at ?? "").trim();
      const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(at);
      if (!m) {
        res.status(400).json({ ok: false, error: "нужен at=ГГГГ-ММ-ДДTЧЧ:ММ (время Астаны)" });
        return;
      }
      const center = Date.UTC(+m[1]!, +m[2]! - 1, +m[3]!, +m[4]!, +m[5]!) - 5 * 3600_000;
      const span = Math.min(Math.max(Number(req.query.min ?? 5) || 5, 1), 180) * 60_000;
      const dir = String(req.query.dir ?? "inbound");
      const snap = await firestore
        .collection("messages")
        .where("createdAt", ">=", admin.firestore.Timestamp.fromMillis(center - span))
        .where("createdAt", "<=", admin.firestore.Timestamp.fromMillis(center + span))
        .orderBy("createdAt", "asc")
        .limit(1000)
        .get();
      const rows = snap.docs
        .map((d) => d.data())
        .filter((x) => dir === "all" || x.direction === dir);
      const convIds = [...new Set(rows.map((x) => String(x.conversationId ?? "")).filter(Boolean))];
      const convs = new Map<string, FirebaseFirestore.DocumentData>();
      await Promise.all(
        convIds.map(async (id) => {
          const c = await firestore.doc(`conversations/${id}`).get();
          if (c.exists) convs.set(id, c.data()!);
        }),
      );
      res.json({
        ok: true,
        окноАстана: `${new Date(center - span + 5 * 3600_000).toISOString().slice(11, 16)}–${new Date(center + span + 5 * 3600_000).toISOString().slice(11, 16)}`,
        найдено: rows.length,
        сообщения: rows.map((x) => {
          const id = String(x.conversationId ?? "");
          const c = convs.get(id) ?? {};
          const ms = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          return {
            время: new Date(ms + 5 * 3600_000).toISOString().slice(11, 19),
            канал: id.startsWith("tg_") ? "telegram" : "whatsapp",
            номер: String(c.phone ?? (id.startsWith("tg_") ? "" : id)) || null,
            имя: String(c.name ?? ""),
            чат: id,
            направление: x.direction,
            текст: String(x.text ?? `[${x.type ?? "?"}]`).slice(0, 80),
          };
        }),
      });
      return;
    }
    if (action === "lastmsgs") {
      const firestore = db();
      const chat = String(req.query.chat ?? "").trim();
      const limit = Math.min(Number(req.query.limit ?? 15) || 15, 50);
      let q = firestore.collection("messages").orderBy("createdAt", "desc").limit(limit);
      if (chat) {
        q = firestore
          .collection("messages")
          .where("conversationId", "==", chat)
          .orderBy("createdAt", "desc")
          .limit(limit);
      }
      const snap = await q.get();
      res.json({
        ok: true,
        messages: snap.docs.map((d) => {
          const x = d.data();
          return {
            id: d.id,
            chat: x.conversationId,
            dir: x.direction,
            status: x.status,
            authorId: x.authorId ?? null,
            crmMessageId: x.crmMessageId ?? null,
            externalMessageId: x.externalMessageId ?? null,
            tgMessageId: x.tgMessageId ?? null,
            at: (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
            text: String(x.text ?? "").slice(0, 60),
          };
        }),
      });
      return;
    }

    // Почему сообщение «пропало»: полный текст и все пометки, из-за которых
    // пузырь в чате мог стать «Сообщение удалено».
    // ?action=msgfull[&chat=<id>][&find=<подстрока>][&limit=300]
    if (action === "msgfull") {
      const firestore = db();
      const chat = String(req.query.chat ?? "").trim();
      const find = String(req.query.find ?? "").trim().toLowerCase();
      const limit = Math.min(Number(req.query.limit ?? 100) || 100, 400);
      let q = firestore.collection("messages").orderBy("createdAt", "desc").limit(limit);
      if (chat) {
        q = firestore
          .collection("messages")
          .where("conversationId", "==", chat)
          .orderBy("createdAt", "desc")
          .limit(limit);
      }
      const snap = await q.get();
      const rows = snap.docs
        .map((d) => {
          const x = d.data();
          return {
            id: d.id,
            chat: x.conversationId,
            dir: x.direction,
            type: x.type ?? null,
            status: x.status ?? null,
            isDeleted: x.isDeleted === true,
            isEdited: x.isEdited === true,
            queued: x.queued === true,
            queueReason: x.queueReason ?? null,
            statusError: x.statusError ?? null,
            textVaried: x.textVaried === true,
            authorId: x.authorId ?? null,
            crmMessageId: x.crmMessageId ?? null,
            externalMessageId: x.externalMessageId ?? null,
            echoMessageId: x.echoMessageId ?? null,
            at: (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
            updatedAt: (x.updatedAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
            text: x.text === null ? null : String(x.text ?? ""),
            contentUri: x.contentUri ?? null,
            mediaUrl: x.mediaUrl ?? null,
            fileName: x.fileName ?? null,
          };
        })
        .filter((r) => (find ? (r.text ?? "").toLowerCase().includes(find) || (r.text === null && r.isDeleted) : true));
      res.json({ ok: true, scanned: snap.size, count: rows.length, messages: rows });
      return;
    }

    // Состояние каналов Wazzup (QR и WABA): подключён ли номер, оплачен ли
    // канал, в каком он статусе. ?action=wazzup
    if (action === "wazzup") {
      try {
        const r = await fetch("https://api.wazzup24.com/v3/channels", {
          headers: { Authorization: `Bearer ${WAZZUP_API_KEY.value()}` },
        });
        const body = (await r.json().catch(() => ({}))) as unknown;
        const raw = Array.isArray(body) ? body : ((body as { data?: unknown }).data ?? []);
        const list = (Array.isArray(raw) ? raw : []) as Record<string, unknown>[];
        res.json({
          ok: r.ok,
          httpStatus: r.status,
          // Ответ не массивом — показываем как есть (ошибка ключа/подписки).
          body: list.length === 0 ? body : undefined,
          channels: list.map((c) => ({
            channelId: c.channelId,
            phone: c.plainId ?? c.name ?? "",
            transport: c.transport,
            state: c.state,
          })),
          raw: r.ok ? undefined : body,
        });
      } catch (e) {
        res.json({ ok: false, error: String(e instanceof Error ? e.message : e) });
      }
      return;
    }

    // Проверка конвертации голосового для WhatsApp без отправки клиенту.
    // ?action=convtest&path=media/out/xxx.m4a
    if (action === "convtest") {
      const src = String(req.query.path ?? "").trim();
      if (!src.startsWith("media/")) {
        res.status(400).json({ ok: false, error: "нужен параметр path (media/...)" });
        return;
      }
      const out = await toWhatsAppAudio(src);
      if (!out) {
        res.json({ ok: false, error: "конвертация не удалась (см. логи функции)" });
        return;
      }
      const [meta] = await admin.storage().bucket().file(out).getMetadata();
      const direct = await publicMediaUrl(out);
      res.json({ ok: true, from: src, to: out, contentType: meta.contentType ?? null, size: meta.size ?? null, direct });
      return;
    }

    // Очередь отправки WhatsApp: что лежит и с какой ошибкой. ?action=outbox
    if (action === "outbox") {
      const firestore = db();
      const snap = await firestore.collection("outbox").orderBy("createdAt", "desc").limit(30).get();
      res.json({
        ok: true,
        items: snap.docs.map((d) => {
          const x = d.data();
          return {
            id: d.id,
            kind: x.kind ?? null,
            chatId: x.chatId ?? null,
            status: x.status ?? null,
            attempts: x.attempts ?? 0,
            mediaPath: x.mediaPath ?? null,
            mediaPathAudio: x.mediaPathAudio ?? null,
            mediaType: x.mediaType ?? null,
            error: x.error ?? null,
            at: (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
          };
        }),
      });
      return;
    }

    // Кто отправляет исходящие в WhatsApp за сутки: автоответ, менеджеры из
    // приложения, ответы из интерфейса Wazzup. ?action=outstats[&hours=24]
    if (action === "outstats") {
      const firestore = db();
      const hours = Math.min(Number(req.query.hours ?? 24) || 24, 72);
      const since = admin.firestore.Timestamp.fromMillis(Date.now() - hours * 3600_000);
      const byAuthor = new Map<string, { count: number; chats: Set<string> }>();
      let scanned = 0;
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      const inboundChats = new Set<string>();
      const repliedChats = new Set<string>();
      const autoChats = new Set<string>();
      const humanChats = new Set<string>();
      for (let page = 0; page < 12; page++) {
        let q = firestore
          .collection("messages")
          .where("createdAt", ">=", since)
          .orderBy("createdAt", "asc")
          .limit(3000);
        if (cursor) q = q.startAfter(cursor);
        const pageSnap = await q.get();
        if (pageSnap.empty) break;
        cursor = pageSnap.docs[pageSnap.docs.length - 1] ?? null;
        scanned += pageSnap.size;
        for (const d of pageSnap.docs) {
          const x = d.data();
          const cid = String(x.conversationId ?? "");
          if (!cid || cid.startsWith("tg_")) continue;
          if (String(x.direction ?? "") === "inbound") {
            inboundChats.add(cid);
            continue;
          }
          const author = x.authorId === "auto"
            ? "автоответ CRM"
            : x.crmMessageId
              ? `менеджер CRM: ${String(x.authorId ?? "?").slice(0, 8)}`
              : `мимо CRM (интерфейс Wazzup): ${String(x.authorName ?? "без имени")}`;
          repliedChats.add(cid);
          if (x.authorId === "auto") autoChats.add(cid); else humanChats.add(cid);
          const cur = byAuthor.get(author) ?? { count: 0, chats: new Set<string>() };
          cur.count += 1;
          cur.chats.add(cid);
          byAuthor.set(author, cur);
        }
        if (pageSnap.size < 3000) break;
      }
      // Чаты, где ушёл ТОЛЬКО автоответ (менеджер так и не написал) — это
      // те клиенты, которых можно не «занимать» лимитом.
      let autoOnly = 0;
      for (const cid of autoChats) if (!humanChats.has(cid)) autoOnly++;
      res.json({
        ok: true,
        hours,
        scanned,
        чатовСВходящими: inboundChats.size,
        чатовМыОтвечали: repliedChats.size,
        толькоАвтоответ: autoOnly,
        авторы: [...byAuthor.entries()]
          .map(([k, v]) => ({ автор: k, сообщений: v.count, чатов: v.chats.size }))
          .sort((a, b) => b.сообщений - a.сообщений),
      });
      return;
    }

    // Розыгрыши: кому и когда ставили картинку. ?action=pranks
    if (action === "pranks") {
      const firestore = db();
      const snap = await firestore.collection("pranks").limit(50).get();
      const cfg = (await firestore.doc("config/prank").get()).data() ?? null;
      res.json({
        ok: true,
        картинкаНастроена: Boolean(cfg?.imageUrl),
        картинка: cfg?.imageUrl ?? null,
        слоты: snap.docs.map((d) => {
          const x = d.data();
          return {
            uid: d.id,
            id: x.id ?? null,
            seconds: x.seconds ?? null,
            from: x.from ?? null,
            url: String(x.url ?? "").slice(0, 90),
            at: (x.at as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
          };
        }),
      });
      return;
    }

    // Кому из записанных можно написать бесплатно: есть Telegram-чат или
    // открыто 24-часовое окно WhatsApp. ?action=reach[&days=14]
    if (action === "reach") {
      const firestore = db();
      const days = Math.min(Number(req.query.days ?? 14) || 14, 60);
      const from = new Date();
      from.setHours(0, 0, 0, 0);
      const to = new Date(from.getTime() + days * 86400_000);

      const digits = (v: unknown) => String(v ?? "").replace(/\D/g, "");
      const phones = new Map<string, string>(); // номер → источник
      for (const col of ["leads", "massages"]) {
        const snap = await firestore
          .collection(col)
          .where("appointmentDate", ">=", admin.firestore.Timestamp.fromDate(from))
          .where("appointmentDate", "<=", admin.firestore.Timestamp.fromDate(to))
          .limit(1000)
          .get();
        for (const d of snap.docs) {
          const x = d.data();
          if (x.archived === true) continue;
          const p = digits(x.phone);
          if (p.length >= 10) phones.set(p, col);
        }
      }

      // Телеграм-чаты с известным номером.
      // ВАЖНО: выбираем только tg_-контакты диапазоном по id. Простой limit
      // сюда не годится — WhatsApp-контакты (цифровые id) идут раньше «tg_»
      // и съедают всю выборку.
      const tg = new Set<string>();
      let tgTotal = 0;
      const tgSnap = await firestore
        .collection("contacts")
        .where(admin.firestore.FieldPath.documentId(), ">=", "tg_")
        .where(admin.firestore.FieldPath.documentId(), "<", "tg`")
        .limit(3000)
        .get();
      for (const d of tgSnap.docs) {
        tgTotal++;
        const p = digits(d.data().phone);
        if (p.length >= 10) tg.add(p);
      }

      // Открытое окно WhatsApp: клиент писал за последние 24 часа.
      const since = Date.now() - 24 * 3600_000;
      let waOpen = 0;
      let tgReach = 0;
      const needTemplate: string[] = [];
      for (const p of phones.keys()) {
        if (tg.has(p)) {
          tgReach++;
          continue;
        }
        const conv = (await firestore.doc(`conversations/${p}`).get()).data();
        const last = (conv?.lastInboundAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        if (last > since) waOpen++;
        else needTemplate.push(p);
      }
      res.json({
        ok: true,
        днейВперёд: days,
        записейСНомером: phones.size,
        telegramКонтактовВсего: tgTotal,
        изНихСНомером: tg.size,
        естьTelegram_бесплатно: tgReach,
        окноWhatsAppОткрыто_бесплатно: waOpen,
        нуженПлатныйШаблон: needTemplate.length,
        примерыПлатных: needTemplate.slice(0, 5),
      });
      return;
    }

    // Разовое добавление быстрых ответов про обучение. Идемпотентно: если
    // ответ с таким заголовком уже есть — пропускаем. ?action=seedtraining
    if (action === "seedtraining") {
      const firestore = db();
      const site = "https://dr-site-toitayev.web.app/";
      const items: { title: string; text: string }[] = [
        {
          title: "Обучение · первый ответ",
          text:
            "Здравствуйте! Спасибо за интерес к обучению у доктора Тойтаева.\n\n" +
            "Это авторская методика остеопатии — от диагностики руками до результата. " +
            "Обучение очное, в Астане: личное наставничество и работа с реальными пациентами под контролем доктора.\n\n" +
            "В группу берём всего 20 человек.\n\n" +
            "Подскажите, пожалуйста, ваш город и есть ли опыт в медицине, массаже или реабилитации?",
        },
        {
          title: "Обучение · как подать заявку",
          text:
            "Чтобы попасть в группу, заполните анкету на сайте — это 3 шага, около 3 минут:\n\n" +
            site +
            "\n\nДоктор Тойтаев читает каждую анкету лично и приглашает подходящих кандидатов на короткое собеседование.\n\n" +
            "Как заполните — напишите нам, мы подскажем следующий шаг.",
        },
        {
          title: "Обучение · кому подходит",
          text:
            "Опыт в медицине не обязателен.\n\n" +
            "В группе учатся люди с разным опытом: врачи, массажисты и специалисты СПА, реабилитологи, тренеры, " +
            "а также те, кто приходит без медицинского образования.\n\n" +
            "Главное — готовность учиться руками и приезжать на практику в Астану.\n\n" +
            "Заполните анкету, и доктор посмотрит именно ваш случай: " + site,
        },
        {
          title: "Обучение · что даёт",
          text:
            "Что вы получаете:\n\n" +
            "• авторскую методику остеопатии доктора Тойтаева — от диагностики руками до результата\n" +
            "• практику на реальных пациентах под контролем доктора\n" +
            "• личное наставничество, а не лекции в записи\n" +
            "• сертификат по окончании\n\n" +
            "Лучший ученик потока становится личным помощником доктора Тойтаева.",
        },
        {
          title: "Обучение · даты старта",
          text:
            "Группа набирается сейчас, мест всего 20. Дату старта объявляем в Instagram и сообщаем всем, кто прошёл анкету.\n\n" +
            "Чтобы не потерять место, заполните анкету заранее: " + site,
        },
        {
          title: "Обучение · стоимость",
          text:
            "Стоимость обучения — 2 000 000 ₸.\n\n" +
            "Для брони места — предоплата 100 000 ₸.\n" +
            "Остаток 1 900 000 ₸ вносится до старта обучения.\n\n" +
            "Место закрепляется после анкеты, собеседования с доктором и предоплаты. " +
            "Мест в группе всего 20.\n\n" +
            "*При отказе от обучения предоплата не возвращается*",
        },
        {
          title: "Обучение · после анкеты",
          text:
            "Спасибо, анкету получили!\n\n" +
            "Доктор Тойтаев читает заявки лично. Если ваша подходит, мы свяжемся с вами " +
            "и назначим короткое собеседование.\n\n" +
            "Обычно отвечаем в течение часа. Если появятся вопросы — пишите сюда.",
        },
        {
          title: "Обучение · адрес",
          text:
            "Обучение проходит очно в Астане, в центре остеопатии Dr. Toitayev.\n\n" +
            "Адрес: улица Шамши Калдаякова, 13.\n" +
            "Маршрут в 2ГИС: https://2gis.kz/astana/geo/70000001115102649",
        },
      ];

      const snap = await firestore.collection("quickReplies").limit(200).get();
      const byTitle = new Map(snap.docs.map((d) => [String(d.data().title ?? "").trim(), d]));
      // Свежие createdAt — новые ответы встают в КОНЕЦ списка и не мешают
      // привычным шаблонам менеджеров. Существующие обновляем по тексту:
      // триггер сам пересоберёт варианты для анти-бана.
      const added: string[] = [];
      const updated: string[] = [];
      for (const it of items) {
        const doc = byTitle.get(it.title);
        if (!doc) {
          await firestore.collection("quickReplies").add({
            title: it.title,
            text: it.text,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          added.push(it.title);
          continue;
        }
        if (String(doc.data().text ?? "") !== it.text) {
          await doc.ref.set({ text: it.text }, { merge: true });
          updated.push(it.title);
        }
      }
      res.json({ ok: true, добавлено: added.length, обновлено: updated.length, названия: [...added, ...updated] });
      return;
    }

    // Догрев «недожатых»: посмотреть кандидатов и запустить вручную.
    // runFollowUps сам не пускает больше 3 за один заход (антибан-темп) —
    // выше этого limit смысла не имеет, лишнее всё равно срежется.
    //   ?action=follow            — кто подходит прямо сейчас (без отправки)
    //   ?action=follow&send=1     — отправить сейчас (не больше 3)
    //   ?action=follow&send=1&limit=1 — тест: отправить максимум одному
    if (action === "follow") {
      // ?action=follow&off=1 / &on=1 — выключить/включить догрев целиком.
      if (String(req.query.off ?? "") === "1" || String(req.query.on ?? "") === "1") {
        const on = String(req.query.on ?? "") === "1";
        await db().doc("config/followUp").set({ enabled: on, updatedAt: ts() }, { merge: true });
        res.json({ ok: true, догрев: on ? "включён" : "выключен", конфиг: (await db().doc("config/followUp").get()).data() });
        return;
      }
      const doSend = String(req.query.send ?? "") === "1";
      if (doSend) {
        const lim = Math.max(1, Math.min(Number(req.query.limit ?? 3) || 3, 3));
        const r = await runFollowUps(token, { force: true, limit: lim });
        res.json({ ok: true, кандидатов: r.candidates, отправлено: r.sent });
        return;
      }
      const list = await followCandidates(Date.now(), 4);
      res.json({
        ok: true,
        кандидатов: list.length,
        список: list.map((c) => ({
          чат: c.id,
          имя: c.name,
          номер: c.phone ? `+${c.phone}` : null,
          молчитЧасов: c.silentHours,
          транспорт: c.transport,
        })),
      });
      return;
    }

    // Автоответ «недоступны» (отпуск/праздники) — проверить и настроить
    // из консоли, тем же переключателем можно управлять и из приложения.
    //   ?action=vacation                  — текущее состояние
    //   ?action=vacation&on=1 / &off=1    — включить/выключить
    //   ?action=vacation&text=...         — задать текст
    if (action === "vacation") {
      const patch: Record<string, unknown> = { updatedAt: ts() };
      if (String(req.query.on ?? "") === "1") patch.enabled = true;
      if (String(req.query.off ?? "") === "1") patch.enabled = false;
      const text = String(req.query.text ?? "").trim();
      if (text) patch.text = text;
      if (Object.keys(patch).length > 1) await db().doc("config/vacationReply").set(patch, { merge: true });
      res.json({ ok: true, конфиг: (await db().doc("config/vacationReply").get()).data() });
      return;
    }

    // ИИ-ответ пациенту — включить/выключить, сменить модель, проверить
    // ключ и промпт БЕЗ реального чата.
    //   ?action=aicfg&on=1 / &off=1        — включить/выключить
    //   ?action=aicfg&testphone=7747...    — работать ТОЛЬКО с этим номером
    //   ?action=aicfg&testphone=off        — снять ограничение по номеру
    //   ?action=aicfg&autosend=1 / &autosend=0 — ИИ отвечает сам (только внутри testphone)
    //   ?action=aicfg&model=claude-opus-5  — сменить модель без деплоя
    //   ?action=aimodels                   — какие модели доступны по ключу
    //   ?action=aitest&text=...&citizen=kz|other  — тестовый прогон (ключ, база знаний)
    if (action === "aicfg") {
      const patch: Record<string, unknown> = { updatedAt: ts() };
      if (String(req.query.on ?? "") === "1") patch.enabled = true;
      if (String(req.query.off ?? "") === "1") patch.enabled = false;
      if (String(req.query.autosend ?? "") === "1") patch.autoSend = true;
      if (String(req.query.autosend ?? "") === "0") patch.autoSend = false;
      const model = String(req.query.model ?? "").trim();
      if (model) patch.model = model;
      const testphone = String(req.query.testphone ?? "").trim();
      if (testphone === "off") patch.testPhone = "";
      else if (testphone) {
        // «8 747…» — внутренний формат, в базе телефоны хранятся с «7».
        let d = testphone.replace(/\D/g, "");
        if (d.length === 11 && d.startsWith("8")) d = `7${d.slice(1)}`;
        patch.testPhone = d;
      }
      if (Object.keys(patch).length > 1) await db().doc("config/aiReply").set(patch, { merge: true });
      res.json({ ok: true, конфиг: (await db().doc("config/aiReply").get()).data() });
      return;
    }
    if (action === "aitest") {
      const text = String(req.query.text ?? "Здравствуйте, сколько стоит приём?").trim();
      const citizen = String(req.query.citizen ?? "kz") === "other" ? "other" : "kz";
      try {
        const draft = await aiTestReply(text, citizen);
        res.json({ ok: true, вопрос: text, подсказка: citizen, ...draft });
      } catch (e) {
        res.json({ ok: false, ошибка: String(e instanceof Error ? e.message : e) });
      }
      return;
    }
    // Автоответчик по обучению (свой выключатель, отдельно от пациентского):
    //   ?action=trcfg&on=1 / &off=1                — включить/выключить
    //   ?action=trcfg&testphone=7747... / =off     — работать только с этим номером
    //   ?action=trcfg&autosend=1 / =0              — отвечать самому, а не черновиком
    //   ?action=trtest&text=...                    — прогон: каким слоем разобрался вопрос
    if (action === "trcfg") {
      const patch: Record<string, unknown> = { updatedAt: ts() };
      if (String(req.query.on ?? "") === "1") patch.enabled = true;
      if (String(req.query.off ?? "") === "1") patch.enabled = false;
      if (String(req.query.autosend ?? "") === "1") patch.autoSend = true;
      if (String(req.query.autosend ?? "") === "0") patch.autoSend = false;
      // allChats=1 — отвечать САМ во всех чатах обучения, а не только на
      // тестовом номере. Отдельный флаг: снять testPhone мало, боевой запуск
      // живым людям должен быть осознанным действием, а не побочным эффектом.
      if (String(req.query.allchats ?? "") === "1") patch.allChats = true;
      if (String(req.query.allchats ?? "") === "0") patch.allChats = false;
      const settle = String(req.query.settlesec ?? "").trim();
      if (settle && /^\d+$/.test(settle)) patch.settleSec = Number(settle);
      const testphone = String(req.query.testphone ?? "").trim();
      if (testphone === "off") patch.testPhone = "";
      else if (testphone) {
        let d = testphone.replace(/\D/g, "");
        if (d.length === 11 && d.startsWith("8")) d = `7${d.slice(1)}`;
        patch.testPhone = d;
      }
      if (Object.keys(patch).length > 1) await db().doc("config/trainingReply").set(patch, { merge: true });
      res.json({ ok: true, конфиг: (await db().doc("config/trainingReply").get()).data() });
      return;
    }
    // Разбор накопившихся неотвеченных чатов обучения.
    //   ?action=trbacklog                       — показать, что ушло бы (без отправки)
    //   ?action=trbacklog&send=1                — отправить
    //   &limit=N (умолчание 40), &hours=N (умолчание 72)
    if (action === "trbacklog") {
      const send = String(req.query.send ?? "") === "1";
      const limit = Math.min(Math.max(Number(req.query.limit ?? 40), 1), 100);
      const hours = Math.min(Math.max(Number(req.query.hours ?? 72), 1), 720);
      try {
        const r = await trainingBacklog({ dry: !send, limit, hours, tgToken: TELEGRAM_BOT_TOKEN.value() });
        res.json({ ok: true, режим: send ? "ОТПРАВКА" : "показ без отправки", ...r });
      } catch (e) {
        res.json({ ok: false, ошибка: String(e instanceof Error ? e.message : e) });
      }
      return;
    }
    if (action === "trtest") {
      const text = String(req.query.text ?? "Сколько стоит обучение?").trim();
      try {
        res.json({ ok: true, вопрос: text, ...(await trainingTestReply(text)) });
      } catch (e) {
        res.json({ ok: false, ошибка: String(e instanceof Error ? e.message : e) });
      }
      return;
    }
    // Сигнал «клиент готов оплатить»:
    //   ?action=paycfg                      — показать настройку
    //   ?action=paycfg&on=1 / &off=1        — включить/выключить
    //   ?action=paycfg&chats=<id>|<id>      — кому слать (пусто → получатели сводки)
    //   ?action=paycfg&test=<текст>         — проверить, срабатывает ли фраза
    if (action === "paycfg") {
      const patch: Record<string, unknown> = { updatedAt: ts() };
      if (String(req.query.on ?? "") === "1") patch.enabled = true;
      if (String(req.query.off ?? "") === "1") patch.enabled = false;
      const chats = String(req.query.chats ?? "").trim();
      if (chats) {
        patch.chatIds = chats
          .split(/[|,\s]+/)
          .map((v) => v.replace(/^tg_/, "").trim())
          .filter((v) => /^\d+$/.test(v));
      }
      if (Object.keys(patch).length > 1) await db().doc("config/paymentAlert").set(patch, { merge: true });
      const test = String(req.query.test ?? "").trim();
      res.json({
        ok: true,
        конфиг: (await db().doc("config/paymentAlert").get()).data() ?? {},
        получателиСводки: (await reportRecipients()).chatIds,
        ...(test ? { проверка: { текст: test, сработает: detectPaymentIntent(test) } } : {}),
      });
      return;
    }
    // Общий рубильник ВСЕХ автосообщений клиенту + сводный статус.
    //   ?action=autoall            — что сейчас включено/выключено
    //   ?action=autoall&off=1      — выключить всё: приветствия, автоответы, ИИ, догрев
    //   ?action=autoall&on=1       — вернуть заготовленные приветствия/автоответы
    // Конверсия «написал → стал лидом» + скорость ответа по часам суток.
    //   ?action=convstats&days=30
    // Загрузка по датам ПРИЁМА (не создания карточки) — сколько записей уже
    // стоит на каждый месяц. ?action=bookinghist
    if (action === "bookinghist") {
      const [leadsSnap, massagesSnap] = await Promise.all([
        db().collection("leads").limit(3000).get(),
        db().collection("massages").limit(3000).get(),
      ]);
      const byMonth = new Map<string, { count: number; archived: number }>();
      let noDate = 0;
      for (const d of [...leadsSnap.docs, ...massagesSnap.docs]) {
        const x = d.data();
        const at = (x.appointmentDate as admin.firestore.Timestamp | undefined)?.toDate();
        if (!at) {
          noDate++;
          continue;
        }
        const month = at.toISOString().slice(0, 7);
        const b = byMonth.get(month) ?? { count: 0, archived: 0 };
        b.count++;
        if (x.archived === true) b.archived++;
        byMonth.set(month, b);
      }
      res.json({
        ok: true,
        сегодня: new Date().toISOString().slice(0, 10),
        безДатыПриёма: noDate,
        поМесяцам: Object.fromEntries(
          [...byMonth.entries()].sort().map(([m, b]) => [m, { всего: b.count, архивных: b.archived, активных: b.count - b.archived }]),
        ),
      });
      return;
    }
    // Справедливое сравнение: сколько записей на месяц X уже стояло РОВНО ЗА
    // N дней до его начала (не «сколько сейчас всего», а «сколько было на
    // этом же этапе в прошлый раз»). ?action=bookingpace&month=2026-09&days=7
    // Кто спрашивал цену и не стал лидом — для оценки размера рассылки.
    // ?action=priceghosts&days=30
    // Поиск сообщений менеджера по ключевым словам — калибровка формулировок
    // перед тем, как строить точный фильтр (например «отказ по противопоказаниям»).
    // ?action=findphrase&words=не можем принять|противопоказан&days=60&limit=20
    // dir=inbound — искать во ВХОДЯЩИХ (например, служебные отметки Wazzup
    // о пропущенных звонках); по умолчанию исходящие менеджеров.
    if (action === "findphrase") {
      const words = String(req.query.words ?? "")
        .split("|")
        .map((w) => w.trim().toLowerCase())
        .filter(Boolean);
      if (words.length === 0) {
        res.status(400).json({ ok: false, error: "нужны words=фраза1|фраза2" });
        return;
      }
      const dir = String(req.query.dir ?? "outbound") === "inbound" ? "inbound" : "outbound";
      const days = Math.min(Math.max(Number(req.query.days ?? 60), 1), 90);
      const limit = Math.min(Math.max(Number(req.query.limit ?? 20), 1), 100);
      const startTs = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86_400_000);
      const out: { chat: string; текст: string; когда: string }[] = [];
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      for (let page = 0; page < 40 && out.length < limit; page++) {
        let q = db().collection("messages").where("createdAt", ">=", startTs).where("direction", "==", dir).orderBy("createdAt", "asc").limit(1000);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        for (const d of snap.docs) {
          const x = d.data();
          if (dir === "outbound" && x.authorId === "auto") continue; // интересуют формулировки живых менеджеров
          const text = String(x.text ?? "");
          const low = text.toLowerCase();
          if (!words.some((w) => low.includes(w))) continue;
          out.push({
            chat: String(x.conversationId ?? x.chatId ?? ""),
            текст: text.slice(0, 200),
            когда: ((x.createdAt as admin.firestore.Timestamp | undefined)?.toDate() ?? new Date()).toISOString().slice(0, 10),
          });
          if (out.length >= limit) break;
        }
        if (snap.size < 1000) break;
      }
      res.json({ ok: true, найдено: out.length, примеры: out });
      return;
    }
    // Чаты, которым отказали в приёме — по реальным формулировкам менеджеров
    // (см. findphrase). Используется, чтобы НЕ звать таких людей рассылкой.
    async function declinedChats(days: number): Promise<Set<string>> {
      const REFUSAL_PHRASES = [
        "не сможем принять", "не можем принять", "не сможем помочь",
        "отказали в приеме", "отказали в приёме", "отказались в приеме", "отказались в приёме",
        "доктор не работает", "вынуждены отказать", "не сможем принять вас", "опасно",
      ];
      const startTs = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86_400_000);
      const out = new Set<string>();
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      for (let page = 0; page < 40; page++) {
        let q = db().collection("messages").where("createdAt", ">=", startTs).where("direction", "==", "outbound").orderBy("createdAt", "asc").limit(1000);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        for (const d of snap.docs) {
          const x = d.data();
          if (x.authorId === "auto") continue;
          const low = String(x.text ?? "").toLowerCase();
          if (REFUSAL_PHRASES.some((w) => low.includes(w))) out.add(String(x.conversationId ?? x.chatId ?? ""));
        }
        if (snap.size < 1000) break;
      }
      return out;
    }

    // Готовый список для рассылки: спрашивали цену, не стали лидом, ИМ НЕ
    // ОТКАЗЫВАЛИ, конкретный транспорт. ?action=broadcastlist&transport=tg&days=30
    if (action === "broadcastlist") {
      const days = Math.min(Math.max(Number(req.query.days ?? 30), 1), 90);
      const transport = String(req.query.transport ?? "tg");
      const startTs = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86_400_000);
      const PRICE_WORDS = ["сколько стоит", "стоимост", "почем", "по чем", "цена", "цену", "цены", "прайс", "скольк будет", "во сколько обойдет", "во сколько обойдёт"];
      const norm = (s: string) => s.toLowerCase().replace(/ё/g, "е").replace(/[^\p{L}\p{N}]+/gu, " ").trim();

      const [leadPhones, declined] = await Promise.all([leadPhoneIndex(db()), declinedChats(120)]);

      const chats = new Map<string, { lastText: string; lastAt: number }>();
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      for (let page = 0; page < 30; page++) {
        let q = db().collection("messages").where("createdAt", ">=", startTs).where("direction", "==", "inbound").orderBy("createdAt", "asc").limit(1000);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        for (const d of snap.docs) {
          const x = d.data();
          const text = norm(String(x.text ?? ""));
          if (!text || !PRICE_WORDS.some((w) => text.includes(w))) continue;
          const cid = String(x.conversationId ?? x.chatId ?? "");
          if (!cid) continue;
          if (transport === "tg" && !cid.startsWith("tg_")) continue;
          if (transport === "wa" && cid.startsWith("tg_")) continue;
          const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          const prev = chats.get(cid);
          if (!prev || at > prev.lastAt) chats.set(cid, { lastText: String(x.text ?? "").slice(0, 80), lastAt: at });
        }
        if (snap.size < 1000) break;
      }

      const ids = [...chats.keys()];
      const result: { chat: string; вопрос: string; когда: string; последнееСообщениеЧасовНазад: number }[] = [];
      let excludedLead = 0;
      let excludedDeclined = 0;
      let excludedRecent = 0;
      const RECENT_MS = 24 * 3600_000;
      for (let i = 0; i < ids.length; i += 100) {
        const refs = ids.slice(i, i + 100).map((id) => db().collection("conversations").doc(id));
        const docs = await db().getAll(...refs);
        for (const doc of docs) {
          const cid = doc.id;
          const c = chats.get(cid);
          if (!c || !doc.exists) continue;
          const data = doc.data() ?? {};
          if (data.blocked === true || isOwnTabTopic(data.topic)) continue;
          const phone = String(data.phone ?? cid.replace(/^tg_/, "")).replace(/\D/g, "");
          if (leadPhones.has(phone)) {
            excludedLead++;
            continue;
          }
          if (declined.has(cid)) {
            excludedDeclined++;
            continue;
          }
          const lastMsgAt = (data.lastMessageAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          const hoursAgo = (Date.now() - lastMsgAt) / 3600_000;
          if (Date.now() - lastMsgAt < RECENT_MS) {
            excludedRecent++;
            continue;
          }
          result.push({ chat: cid, вопрос: c.lastText, когда: new Date(c.lastAt).toISOString().slice(0, 10), последнееСообщениеЧасовНазад: Math.round(hoursAgo) });
        }
      }

      res.json({
        ok: true,
        транспорт: transport,
        период: `${days} дней`,
        готовыхКОтправке: result.length,
        исключеноСталиЛидом: excludedLead,
        исключеноОтказано: excludedDeclined,
        исключеноАктивныеПоследние24ч: excludedRecent,
        список: result,
      });
      return;
    }
    if (action === "priceghosts") {
      const days = Math.min(Math.max(Number(req.query.days ?? 30), 1), 90);
      const startTs = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86_400_000);
      const PRICE_WORDS = ["сколько стоит", "стоимост", "почем", "по чем", "цена", "цену", "цены", "прайс", "скольк будет", "во сколько обойдет", "во сколько обойдёт"];
      const norm = (s: string) => s.toLowerCase().replace(/ё/g, "е").replace(/[^\p{L}\p{N}]+/gu, " ").trim();

      const leadPhones = await leadPhoneIndex(db());

      const chats = new Map<string, { phone: string; lastText: string; lastAt: number; topic: string | null }>();
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      for (let page = 0; page < 30; page++) {
        let q = db()
          .collection("messages")
          .where("createdAt", ">=", startTs)
          .where("direction", "==", "inbound")
          .orderBy("createdAt", "asc")
          .limit(1000);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        for (const d of snap.docs) {
          const x = d.data();
          const text = norm(String(x.text ?? ""));
          if (!text || !PRICE_WORDS.some((w) => text.includes(w))) continue;
          const cid = String(x.conversationId ?? x.chatId ?? "");
          if (!cid) continue;
          const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          const prev = chats.get(cid);
          if (!prev || at > prev.lastAt) chats.set(cid, { phone: "", lastText: String(x.text ?? "").slice(0, 80), lastAt: at, topic: null });
        }
        if (snap.size < 1000) break;
      }

      // Гражданство/тема чата — подтягиваем карточки пачками.
      const ids = [...chats.keys()];
      let ghostsWa = 0;
      let ghostsTg = 0;
      const sample: { chat: string; вопрос: string; когда: string }[] = [];
      for (let i = 0; i < ids.length; i += 100) {
        const refs = ids.slice(i, i + 100).map((id) => db().collection("conversations").doc(id));
        const docs = await db().getAll(...refs);
        for (const doc of docs) {
          const cid = doc.id;
          const c = chats.get(cid);
          if (!c || !doc.exists) continue;
          const data = doc.data() ?? {};
          if (data.blocked === true || isOwnTabTopic(data.topic)) continue;
          const phone = String(data.phone ?? cid.replace(/^tg_/, ""));
          if (leadPhones.has(phone.replace(/\D/g, ""))) continue; // всё же стал лидом — не «пропал»
          if (cid.startsWith("tg_")) ghostsTg++;
          else ghostsWa++;
          if (sample.length < 15) sample.push({ chat: cid, вопрос: c.lastText, когда: new Date(c.lastAt).toISOString().slice(0, 10) });
        }
      }

      const total = ghostsWa + ghostsTg;
      res.json({
        ok: true,
        период: `${days} дней`,
        спрашивалиЦенуИНеСталиЛидом: total,
        изНихWhatsApp: ghostsWa,
        изНихTelegram: ghostsTg,
        стоимостьРассылкиПо10тенге: `${total * 10} тенге`,
        примеры: sample,
      });
      return;
    }
    // Открыто ли 24-часовое окно WhatsApp по списку номеров.
    // ?action=windowcheck&phones=77021104028|79126977771|...
    // Разовая рассылка «приём переносится» — сегодняшним записям, 25.08.
    // wa — обычный номер (окно открыто), tg — тот же человек, но чат нашёлся
    // только в Telegram (WhatsApp либо без чата вовсе, либо окно закрыто).
    // ?action=cancelbroadcast (показ) / &send=1 (реальная отправка)
    if (action === "cancelbroadcast") {
      const send = String(req.query.send ?? "") === "1";
      const TEXT_TMPL = (name: string) =>
        `Здравствуйте, ${name}! К сожалению, сегодняшний приём необходимо перенести на другой день в связи с плохим самочувствием врача.\n\nПриносим искренние извинения за неудобства. *Ваша сегодняшняя запись переносится. Пожалуйста, напишите нам удобные для вас дату и время, и мы перенесём вашу запись.*\n\nСпасибо за понимание!`;

      const wa: { phone: string; name: string }[] = [
        { phone: "77055184300", name: "Леонид" },
        { phone: "77773222077", name: "Нуртай" },
        { phone: "77765456107", name: "Кулярам" },
        { phone: "77774980998", name: "Елизавета" },
        { phone: "77753358327", name: "Карлан" },
        { phone: "79109359396", name: "Светлана" },
        { phone: "77015776229", name: "Перизат" },
        { phone: "77051376804", name: "Ольга" },
        { phone: "77077026652", name: "Аида" },
        { phone: "77071919195", name: "Майра" },
        { phone: "77012265825", name: "Алия" },
        { phone: "77775342130", name: "Юрий" },
        { phone: "77759004008", name: "Нуралы" },
        { phone: "77754000771", name: "Арман" },
        { phone: "77018144595", name: "Маржан" },
        { phone: "77056707277", name: "Абзал" },
        { phone: "77078568788", name: "Кенес" },
      ];
      const tg: { chatId: string; name: string }[] = [
        { chatId: "197511018", name: "Сергей и Татьяна" }, // +79126977771, WA-чата нет
        { chatId: "499283397", name: "Алла" }, // +77775910110, WA-чата нет
      ];
      // WA-чат есть, но окно закрыто больше суток — писать нельзя без шаблона,
      // и Telegram-альтернативы не нашлось. Отдаём менеджеру для звонка.
      const needsCall = [
        { phone: "+79874995181", name: "Халида", причина: "нет чата вообще ни в одном канале" },
        { phone: "+77767771977", name: "Бахытылы", причина: "WhatsApp: не писала ~13 дней, окно закрыто" },
        { phone: "+77026408638", name: "Эмануила", причина: "WhatsApp: не писала ~10 дней, окно закрыто" },
        { phone: "+77771205777", name: "Найля", причина: "WhatsApp: не писала ~6.5 дней, окно закрыто" },
      ];

      const results: { канал: string; кому: string; текст: string; статус: string }[] = [];
      let i = 0;
      for (const r of wa) {
        const text = TEXT_TMPL(r.name);
        if (send) {
          await enqueue({
            kind: "text",
            chatId: r.phone,
            text: uniquifyText(text, r.phone),
            authorId: "auto",
            crmMessageId: randomUUID(),
            reason: "delay",
            nextAttemptAt: admin.firestore.Timestamp.fromMillis(Date.now() + 3000 + i * 6000),
          });
        }
        results.push({ канал: "WhatsApp", кому: `${r.name} (+${r.phone})`, текст: text.slice(0, 60), статус: send ? `в очереди, через ${3 + i * 6}с` : "показ" });
        i++;
      }
      for (const r of tg) {
        const text = TEXT_TMPL(r.name).replace(/\*/g, ""); // Telegram-бот шлёт без parse_mode — звёздочки не станут жирным
        if (send) {
          try {
            const sent = await tgSendTextApi(TELEGRAM_BOT_TOKEN.value(), { chatId: Number(r.chatId), text });
            const convId = `tg_${r.chatId}`;
            await db()
              .collection("messages")
              .doc(`tg_${r.chatId}_${sent.message_id}`)
              .set({
                conversationId: convId, chatId: convId, tgMessageId: sent.message_id,
                direction: "outbound", type: "text", text, status: "sent",
                authorId: "auto", createdAt: ts(),
              });
            await db().doc(`conversations/${convId}`).set(
              { lastMessageAt: ts(), lastMessagePreview: text.slice(0, 120), lastOutbound: true, lastAuthorId: "auto", lastAuthorName: null, updatedAt: ts() },
              { merge: true },
            );
            results.push({ канал: "Telegram", кому: `${r.name} (tg_${r.chatId})`, текст: text.slice(0, 60), статус: "отправлено" });
          } catch (e) {
            results.push({ канал: "Telegram", кому: `${r.name} (tg_${r.chatId})`, текст: text.slice(0, 60), статус: `ОШИБКА: ${String(e instanceof Error ? e.message : e)}` });
          }
        } else {
          results.push({ канал: "Telegram", кому: `${r.name} (tg_${r.chatId})`, текст: text.slice(0, 60), статус: "показ" });
        }
      }

      res.json({ ok: true, режим: send ? "ОТПРАВКА" : "показ без отправки", отправлено: results.length, список: results, требуютЗвонка: needsCall });
      return;
    }
    // Какие чаты помечены как личные (забранные владельцем). ?action=privatechats
    // Поиск дублей автосообщений: один и тот же чат получил похожий текст
    // от authorId=auto больше одного раза. ?action=dupauto&hours=24
    if (action === "dupauto") {
      const hours = Math.min(Math.max(Number(req.query.hours ?? 24), 1), 72);
      const since = admin.firestore.Timestamp.fromMillis(Date.now() - hours * 3600_000);
      // Ключ текста: только буквы/цифры и первые 40 символов — варианты
      // автоответа отличаются приветствием и невидимой уникализацией,
      // побайтовое сравнение дубли бы не поймало.
      const key = (t: string) => t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "").slice(0, 40);
      const byChat = new Map<string, Map<string, { n: number; при: string[]; текст: string }>>();
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      let scanned = 0;
      for (let page = 0; page < 40; page++) {
        let q = db()
          .collection("messages")
          .where("createdAt", ">=", since)
          .where("direction", "==", "outbound")
          .orderBy("createdAt", "asc")
          .limit(1000);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        scanned += snap.size;
        for (const d of snap.docs) {
          const x = d.data();
          if (String(x.authorId ?? "") !== "auto") continue;
          const text = String(x.text ?? "");
          if (!text) continue;
          const cid = String(x.conversationId ?? x.chatId ?? "");
          const k = key(text);
          if (!k) continue;
          const m = byChat.get(cid) ?? new Map();
          const cur = m.get(k) ?? { n: 0, при: [] as string[], текст: text.slice(0, 60) };
          cur.n++;
          cur.при.push(((x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? "").slice(11, 19));
          m.set(k, cur);
          byChat.set(cid, m);
        }
        if (snap.size < 1000) break;
      }
      const dups: { чат: string; сколько: number; когда: string[]; текст: string }[] = [];
      // Несколько РАЗНЫХ автосообщений в одном чате: со стороны клиента это
      // тоже выглядит как «бот написал дважды», хотя тексты не совпадают
      // (например, приветствие и следом «Информация о приёме»).
      const multi: { чат: string; сообщений: number; тексты: string[] }[] = [];
      for (const [cid, m] of byChat) {
        for (const v of m.values()) {
          if (v.n > 1) dups.push({ чат: cid, сколько: v.n, когда: v.при, текст: v.текст });
        }
        const total = [...m.values()].reduce((a, v) => a + v.n, 0);
        if (m.size > 1) multi.push({ чат: cid, сообщений: total, тексты: [...m.values()].map((v) => v.текст) });
      }
      dups.sort((a, b) => b.сколько - a.сколько);
      multi.sort((a, b) => b.сообщений - a.сообщений);
      res.json({
        ok: true,
        просмотреноСообщений: scanned,
        чатовСОдинаковымДублем: dups.length,
        чатовСНесколькимиАвтосообщениями: multi.length,
        одинаковые: dups.slice(0, 15),
        разные: multi.slice(0, 15),
      });
      return;
    }
    // Кому мы сегодня ответили, а он замолчал. ?action=silenttoday
    //   &send=1&text=...  — отправить (текст обязателен)
    if (action === "silenttoday") {
      const send = String(req.query.send ?? "") === "1";
      const text = String(req.query.text ?? "").trim();
      const TZ = 5 * 3600_000; // Астана
      const now = Date.now();
      const todayStart = (() => {
        const l = new Date(now + TZ);
        return Date.UTC(l.getUTCFullYear(), l.getUTCMonth(), l.getUTCDate()) - TZ;
      })();
      // days=1 — только сегодня (умолчание). Больше — захватываем прошлые дни:
      // тех, кто замолчал раньше и кому дожим ещё не уходил. Для WhatsApp это
      // почти всегда упрётся в закрытое 24-часовое окно — такие отсеются ниже.
      const days = Math.min(Math.max(Number(req.query.days ?? 1), 1), 30);
      // fromts (мс) — точная нижняя граница окна: «все чаты с вчерашних
      // 20:00», а не только целыми днями.
      const fromTs = Number(req.query.fromts ?? NaN);
      const dayStart = Number.isFinite(fromTs)
        ? fromTs
        : days <= 1 ? todayStart : todayStart - (days - 1) * 86_400_000;
      const leadPhones = await leadPhoneIndex(db());

      // Кому этот дожим уже уходил — второй раз не пишем.
      //
      // Метку silentFollowUpAt мы ставим при отправке (см. ниже), но ПЕРВАЯ
      // волна ушла до того, как метка появилась. Поэтому дополнительно
      // опознаём её по характерной фразе в исходящих за сегодня — иначе те
      // 118 человек получили бы сообщение повторно.
      const alreadySent = new Set<string>();
      {
        let mc: FirebaseFirestore.QueryDocumentSnapshot | null = null;
        for (let page = 0; page < 40; page++) {
          let mq = db()
            .collection("messages")
            // Смотрим на 3 дня назад, а не только сегодня: человек, которому
            // дожим ушёл вчера, мог написать снова — и получил бы тот же
            // вопрос повторно уже на следующий день.
            .where("createdAt", ">=", admin.firestore.Timestamp.fromMillis(dayStart - 3 * 86_400_000))
            .where("direction", "==", "outbound")
            .orderBy("createdAt", "asc")
            .limit(1000);
          if (mc) mq = mq.startAfter(mc);
          const ms = await mq.get();
          if (ms.empty) break;
          mc = ms.docs[ms.docs.length - 1] ?? null;
          for (const d of ms.docs) {
            const t = String(d.data().text ?? "").toLowerCase();
            // Универсальный текст волны («Мы на связи») тоже считается: метка
            // silentFollowUpAt есть не у всех, кому он уходил (планировщик
            // догрева её не ставит), и без этого человек получал бы его дважды.
            if (t.includes("определились по записи") || t.includes("определились с записью") || t.includes("мы на связи")) {
              alreadySent.add(String(d.data().conversationId ?? d.data().chatId ?? ""));
            }
          }
          if (ms.size < 1000) break;
        }
      }

      const snap = await db()
        .collection("conversations")
        .where("lastMessageAt", ">=", admin.firestore.Timestamp.fromMillis(dayStart))
        .orderBy("lastMessageAt", "desc")
        .limit(3000)
        .get();

      // Минимум тишины: человеку, которому мы ответили пять минут назад,
      // вопрос «ну что, решили?» выглядит навязчивым и как сбой системы.
      const minHours = Number(req.query.minhours ?? 3);
      // exclude=id1,id2 — ручные исключения после просмотра списка: действующий
      // пациент с остатком оплаты, человек, которому мы сами обещали
      // «уточню» — им вопрос «хотите записаться?» неуместен, а метку дожима
      // ставить нельзя: дожим им не уходил.
      const exclude = new Set(
        String(req.query.exclude ?? "")
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean),
      );
      const transportOnly = String(req.query.transport ?? "").trim().toLowerCase();
      const rows: { чат: string; имя: string; молчитЧасов: number; окно: string }[] = [];
      const skipped = { уже_лид: 0, окно_закрыто: 0, тема_своя: 0, нет_входящих: 0, ответил_клиент: 0, ещё_рано: 0, уже_писали: 0, разговор_закрыт: 0, исключён_вручную: 0, другой_канал: 0 };
      for (const d of snap.docs) {
        const c = d.data();
        if (c.blocked === true) continue;
        if (exclude.has(d.id)) {
          skipped.исключён_вручную++;
          continue;
        }
        if (alreadySent.has(d.id) || c.silentFollowUpAt != null) {
          skipped.уже_писали++;
          continue;
        }
        if (isOwnTabTopic(c.topic)) {
          skipped.тема_своя++;
          continue;
        }
        // Последнее слово должно быть за НАМИ: если клиент ответил, догонять
        // его этим сообщением нельзя — разговор уже идёт.
        if (c.lastOutbound !== true) {
          skipped.ответил_клиент++;
          continue;
        }
        const lastIn = (c.lastInboundAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        if (lastIn === 0) {
          skipped.нет_входящих++;
          continue;
        }
        const phone = String(c.phone ?? d.id).replace(/\D/g, "");
        if (leadPhones.has(phone)) {
          skipped.уже_лид++;
          continue;
        }
        // WhatsApp: свободный текст уходит только внутри 24-часового окна.
        const isTg = d.id.startsWith("tg_");
        // transport=tg | wa — волна только по одному каналу («по телеге, не
        // на ватсап»): WhatsApp-очередь иногда лучше не трогать вечером.
        if ((transportOnly === "tg" && !isTg) || (transportOnly === "wa" && isTg)) {
          skipped.другой_канал++;
          continue;
        }
        const open = now - lastIn < 24 * 3600_000;
        if (!isTg && !open) {
          skipped.окно_закрыто++;
          continue;
        }
        // Считаем тишину от НАШЕГО последнего сообщения: клиент молчит
        // именно после ответа, а не с момента, когда сам писал.
        const lastOut = (c.lastMessageAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        const silentH = (now - lastOut) / 3600_000;
        if (silentH < minHours) {
          skipped.ещё_рано++;
          continue;
        }
        rows.push({
          чат: d.id,
          имя: String(c.name ?? d.id),
          молчитЧасов: Math.round(silentH * 10) / 10,
          окно: isTg ? "telegram" : "открыто",
        });
      }

      // Разговор УЖЕ закончен по-хорошему: клиент отказался или отложил, а
      // менеджер ответил коротким «Хорошо», «Спасибо», «Будем ждать». Вопрос
      // «определились по записи?» после такого выглядит так, будто мы не
      // читали переписку.
      //
      // Отличаем по НАШЕМУ последнему сообщению: короткая вежливая реплика
      // без вопроса и без информации. Длинный ответ с ценами и датами —
      // не закрытие, там человек ещё думает.
      // Казахские и прощальные реплики тоже закрывают разговор: в волне 06.09
      // «Жақсы» и «До свидания)» прошли фильтр и получили «хотите записаться?».
      // Казахские слова менеджеры пишут и без спецбукв («жаксы» вместо
      // «жақсы»): нормализация убирает только знаки, к/қ остаются разными.
      const CLOSERS_DEF = "хорошо|спасибо|поняла|понял|ок|окей|договорились|будем ждать|ждем вас|ждём вас|всего доброго|всего хорошего|хорошего дня|хорошего вечера|до свидания|обращайтесь|конечно|прекрасно|отлично|жақсы|жаксы|жарайды|жарайды|рахмет|рақмет|күтеміз|кутемиз|хабарласыңыз|хабарласыныз";
      const closers = String(req.query.closers ?? CLOSERS_DEF)
        .split("|")
        .map((s) => s.trim().toLowerCase())
        .filter(Boolean);
      const skipClosers = String(req.query.skipclosers ?? "") === "1";
      const withLast = String(req.query.showlast ?? "") === "1" || skipClosers;
      const closed: { чат: string; последнееНаше: string }[] = [];
      if (withLast) {
        // Без фильтра по direction: составного индекса
        // (conversationId + direction + createdAt) в проекте нет, и такой
        // запрос молча падал — последнее сообщение приходило пустым, а
        // фильтр «разговор закрыт» из-за этого не срабатывал ни разу.
        const lastOf = async (chat: string): Promise<string> => {
          const s = await db()
            .collection("messages")
            .where("conversationId", "==", chat)
            .orderBy("createdAt", "desc")
            .limit(10)
            .get();
          for (const d of s.docs) {
            if (d.data().direction === "outbound") return String(d.data().text ?? "");
          }
          return "";
        };
        const texts = await Promise.all(rows.map((r) => lastOf(r.чат).catch(() => "")));
        const keep: typeof rows = [];
        for (let k = 0; k < rows.length; k++) {
          const raw = texts[k] ?? "";
          // Только буквы и цифры: эмодзи, точки и невидимая уникализация
          // текста не должны мешать сравнению.
          const t = raw.toLowerCase().replace(/[^\p{L}\p{N}\s]+/gu, " ").replace(/\s+/g, " ").trim();
          const isClosing = t.length > 0 && t.length <= 45 && !raw.includes("?") && closers.some((c) => t === c || t.startsWith(`${c} `));
          // Отказ с нашей стороны (противопоказания, не принимаем) — тоже
          // закрытый разговор, каким бы длинным ни был текст отказа.
          const REFUSE = [
            "не сможем принять", "не можем принять", "принять не сможем", "не сможем вас принять", "не получится принять", "вынуждены отказать",
            "не можем помочь", "не сможем помочь", "не можем вам помочь", "не сможем вам помочь",
            // Отказ по диагнозу — самая частая формулировка врачей клиники:
            // «Болезнь Бехтерева не лечим», «с последствиями инсульта доктор
            // не работает», казахское «инсульттермен жұмыс жасамаймыз».
            "не лечим", "не лечит", "доктор не работает", "врач не работает", "не работаем с",
            "жасамаймыз", "емдемейміз", "емдемеймыз", "қабылдамаймыз", "кабылдамаймыз",
            // «К сожалению ЗПРР не принимаем» — диагноз стоит между словами,
            // поэтому ловим само «не принимаем», а не «не принимаем с».
            "не принимаем", "к сожалению нет",
          ];
          const refused = REFUSE.some((w) => t.includes(w));
          if (skipClosers && (isClosing || refused)) {
            closed.push({ чат: rows[k]!.чат, последнееНаше: raw.slice(0, 60) });
            skipped.разговор_закрыт++;
            continue;
          }
          (rows[k] as { последнееНаше?: string }).последнееНаше = raw.slice(0, 60);
          keep.push(rows[k]!);
        }
        rows.length = 0;
        rows.push(...keep);
      }

      // Порция за один запуск: 90 писем занимают канал на полчаса и мешают
      // менеджерам отвечать вживую. Берём тех, кто молчит ДОЛЬШЕ всех — они
      // ближе всего к тому, чтобы уйти совсем, а свежие ещё могут ответить
      // сами.
      rows.sort((a, b) => b.молчитЧасов - a.молчитЧасов);
      const limit = Math.min(Math.max(Number(req.query.limit ?? rows.length), 1), rows.length || 1);
      const всегоПодходит = rows.length;
      if (limit < rows.length) rows.length = limit;

      if (!send) {
        const tgN = rows.filter((r) => r.чат.startsWith("tg_")).length;
        const oldest = rows.length > 0 ? Math.max(...rows.map((r) => r.молчитЧасов)) : 0;
        res.json({
          ok: true,
          режим: "показ",
          днейНазад: days,
          порогТишиныЧасов: minHours,
          всегоПодходит,
          найдено: rows.length,
          изНихTelegram: tgN,
          изНихWhatsApp: rows.length - tgN,
          самыйДавнийМолчитЧасов: Math.round(oldest),
          пропущено: skipped,
          закрытыеРазговоры: closed.slice(0, 40),
          // showall=1 — весь список: волна перед отправкой проверяется глазами
          // целиком, а не первые 40 (отказы прятались в хвосте).
          чаты: String(req.query.showall ?? "") === "1" ? rows : rows.slice(0, 40),
        });
        return;
      }
      if (!text) {
        res.status(400).json({ ok: false, error: "нужен text" });
        return;
      }
      // Пауза между письмами WhatsApp: gapmin..gapmax секунд, случайная
      // (по умолчанию ровно 25). Планировщик добирает готовые раз в минуту.
      const gapMin = Math.max(3, Number(req.query.gapmin ?? 25) || 25);
      const gapMax = Math.max(gapMin, Number(req.query.gapmax ?? gapMin) || gapMin);
      let dueAt = Date.now() + 4000;
      const sent: string[] = [];
      for (const r of rows) {
        if (r.чат.startsWith("tg_")) {
          try {
            const tgId = r.чат.replace(/^tg_/, "");
            const m = await tgSendTextApi(TELEGRAM_BOT_TOKEN.value(), { chatId: Number(tgId), text });
            await db().collection("messages").doc(`tg_${tgId}_${m.message_id}`).set({
              conversationId: r.чат, chatId: r.чат, tgMessageId: m.message_id,
              direction: "outbound", type: "text", text, status: "sent",
              authorId: "auto", createdAt: ts(),
            });
            await db().doc(`conversations/${r.чат}`).set(
              {
                lastMessageAt: ts(),
                lastMessagePreview: text.slice(0, 120),
                lastOutbound: true,
                lastAuthorId: "auto",
                lastAuthorName: null,
                // Метка дожима: следующий запуск этого человека пропустит.
                silentFollowUpAt: ts(),
                updatedAt: ts(),
              },
              { merge: true },
            );
            sent.push(r.чат);
          } catch (e) {
            const msg = String(e instanceof Error ? e.message : e);
            console.error("silenttoday tg fail", r.чат, msg);
            // «bot was blocked by the user» — окончательно: человек заблокировал
            // бота, писать ему больше нельзя. Помечаем чат, чтобы следующие
            // волны его не перебирали (Shakhrezat попадал в список три раза).
            if (/blocked by the user|user is deactivated|chat not found/i.test(msg)) {
              await db().doc(`conversations/${r.чат}`).set({ blocked: true, blockedAt: ts(), blockedReason: msg.slice(0, 120) }, { merge: true });
            }
          }
        } else {
          await enqueue({
            kind: "text", chatId: r.чат, text: uniquifyText(text, r.чат), authorId: "auto",
            crmMessageId: randomUUID(), reason: "delay", autoReply: true,
            nextAttemptAt: admin.firestore.Timestamp.fromMillis(dueAt),
          });
          dueAt += (gapMin + Math.random() * (gapMax - gapMin)) * 1000;
          // Метку ставим СРАЗУ при постановке в очередь, а не после отправки:
          // сообщение уйдёт через десятки минут, и повторный запуск за это
          // время выбрал бы того же человека второй раз.
          await db().doc(`conversations/${r.чат}`).set({ silentFollowUpAt: ts() }, { merge: true });
          sent.push(r.чат);
        }
      }
      res.json({ ok: true, режим: "ОТПРАВКА", отправлено: sent.length, пропущено: skipped });
      return;
    }
    // Забрать чат себе СЕРВЕРОМ — проверка, доходит ли запись до базы.
    // ?action=takechat&id=<chatId>&uid=<uid>   (uid=off — вернуть всем)
    if (action === "takechat") {
      const id = String(req.query.id ?? "").trim();
      const uid = String(req.query.uid ?? "").trim();
      if (!id || !uid) {
        res.status(400).json({ ok: false, error: "нужны id и uid" });
        return;
      }
      const ref2 = db().doc(`conversations/${id}`);
      await ref2.set(
        {
          privateOwnerUid: uid === "off" ? admin.firestore.FieldValue.delete() : uid,
          updatedAt: ts(),
        },
        { merge: true },
      );
      const after = (await ref2.get()).data() ?? {};
      res.json({ ok: true, чат: id, записаноВБазе: after.privateOwnerUid ?? null });
      return;
    }
    // Найти лиды по ИМЕНИ (часть имени, регистр не важен). ?action=findleadname&q=Бибигуль
    if (action === "findleadname") {
      const q = String(req.query.q ?? "").trim().toLowerCase();
      if (q.length < 2) {
        res.status(400).json({ ok: false, error: "нужен q" });
        return;
      }
      const snap = await db().collection("leads").limit(3000).get();
      const rows = snap.docs
        .filter((d) => String(d.data().name ?? "").toLowerCase().includes(q))
        .map((d) => {
          const x = d.data();
          return {
            id: d.id,
            номер: x.leadNumber ?? null,
            имя: x.name ?? null,
            телефон: x.phone ?? null,
            приём: (x.appointmentDate as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
            время: x.appointmentTime ?? null,
            предоплата: x.prepayment ?? null,
            архив: x.archived === true,
            создан: (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
          };
        })
        .sort((a, b) => String(a.создан).localeCompare(String(b.создан)));
      res.json({ ok: true, найдено: rows.length, лиды: rows });
      return;
    }
    // Найти лиды по номеру — чтобы сверить дубли ПЕРЕД удалением.
    // ?action=findlead&phone=77711077691
    if (action === "findlead") {
      const digits = String(req.query.phone ?? "").replace(/\D/g, "");
      if (digits.length < 5) {
        res.status(400).json({ ok: false, error: "нужен phone" });
        return;
      }
      const snap = await db().collection("leads").limit(3000).get();
      const rows = snap.docs
        .filter((d) => String(d.data().phone ?? "").replace(/\D/g, "") === digits)
        .map((d) => {
          const x = d.data();
          return {
            id: d.id,
            номер: x.leadNumber ?? null,
            имя: x.name ?? null,
            телефон: x.phone ?? null,
            приём: (x.appointmentDate as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
            время: x.appointmentTime ?? null,
            предоплата: x.prepayment ?? null,
            валюта: x.currency ?? null,
            архив: x.archived === true,
            создан: (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
            авторUid: x.createdBy ?? null,
          };
        })
        .sort((a, b) => String(a.создан).localeCompare(String(b.создан)));
      res.json({ ok: true, найдено: rows.length, лиды: rows });
      return;
    }
    // Почему поиск в приложении не находит чат: прогоняем те же запросы,
    // что и клиент (префикс по phone и по name во всех написаниях номера),
    // Кому из списка номеров отправляли АКЦИЮ: ищем в переписке каждого
    // исходящие со словами «акци»/«скидк». Чат берём и WhatsApp (id = номер),
    // и Telegram (карточка с этим номером).
    // ?action=promowho&phones=77011234567,87011234568,...
    if (action === "promowho") {
      const phones = String(req.query.phones ?? "")
        .split(",")
        .map((s) => s.replace(/\D/g, ""))
        .map((d) => (d.length === 11 && d.startsWith("8") ? `7${d.slice(1)}` : d))
        .filter((d) => d.length >= 10);
      if (phones.length === 0) {
        res.status(400).json({ ok: false, error: "нужен phones=через,запятую" });
        return;
      }
      const out: Record<string, unknown>[] = [];
      for (const p of [...new Set(phones)]) {
        // Все чаты этого номера: WhatsApp-документ с id=номер + телеграм-чаты.
        const chatIds = new Set<string>([p]);
        try {
          const tg = await db().collection("conversations").where("phone", "==", p).limit(5).get();
          for (const d of tg.docs) chatIds.add(d.id);
        } catch {
          /* поиск по phone не удался — проверим хотя бы WhatsApp */
        }
        let акция: string | null = null;
        let скидка: string | null = null;
        for (const cid of chatIds) {
          const snap = await db()
            .collection("messages")
            .where("conversationId", "==", cid)
            .orderBy("createdAt", "desc")
            .limit(300)
            .get();
          for (const d of snap.docs) {
            const x = d.data();
            if (x.direction !== "outbound") continue;
            const text = String(x.text ?? "").toLowerCase();
            const when = (x.createdAt as admin.firestore.Timestamp | undefined)
              ?.toDate()
              .toISOString()
              .slice(5, 16)
              .replace("T", " ");
            if (!акция && text.includes("акци")) акция = when ?? "да";
            if (!скидка && text.includes("скидк")) скидка = when ?? "да";
          }
        }
        out.push({ телефон: p, шаблонАкции: акция, вопросПроСкидку: скидка });
      }
      res.json({ ok: true, проверено: out.length, номера: out });
      return;
    }
    // Удалённый журнал приложения с телефона менеджера (clientLogs/{uid}).
    // ?action=clientlog&uid=<uid>  или  &email=user1@gmail.com
    if (action === "clientlog") {
      let uid = String(req.query.uid ?? "").trim();
      const email = String(req.query.email ?? "").trim();
      if (!uid && email) {
        try {
          uid = (await admin.auth().getUserByEmail(email)).uid;
        } catch {
          res.status(404).json({ ok: false, error: "аккаунт не найден" });
          return;
        }
      }
      if (!uid) {
        res.status(400).json({ ok: false, error: "нужен uid или email" });
        return;
      }
      const d = (await db().doc(`clientLogs/${uid}`).get()).data();
      if (!d) {
        res.json({ ok: true, uid, журнал: "пусто — приложение ещё не прислало логи" });
        return;
      }
      res.json({
        ok: true,
        uid,
        ос: d.os ?? null,
        обновлён: (d.updatedAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
        строки: ((d.lines ?? []) as string[]).slice(-80),
      });
      return;
    }
    // Планки конкурса без приложения: командная и личные.
    // ?action=contestcfg                       — показать
    // ?action=contestcfg&daily=50&weekly=300   — командная
    // ?action=contestcfg&pdaily=10&pweekly=60  — личная всем
    // ?action=contestcfg&uid=<uid>&daily=18    — личная одному (weekly=…)
    // ?action=contestcfg&uid=<uid>&reset=1     — одному «как у всех»
    if (action === "contestcfg") {
      const ref2 = db().doc("config/contest");
      const n = (k: string): number | null => {
        const v = Number(req.query[k] ?? NaN);
        return Number.isFinite(v) && v >= 1 ? Math.round(v) : null;
      };
      const uid = String(req.query.uid ?? "").trim();
      const patch: Record<string, unknown> = {};
      if (uid) {
        if (String(req.query.reset ?? "") === "1") {
          patch.personalByUid = { [uid]: admin.firestore.FieldValue.delete() };
        } else {
          const d = n("daily"), w = n("weekly"), m = n("monthly");
          if (d != null || w != null || m != null) {
            patch.personalByUid = {
              [uid]: { ...(d != null ? { daily: d } : {}), ...(w != null ? { weekly: w } : {}), ...(m != null ? { monthly: m } : {}) },
            };
          }
        }
      } else {
        const d = n("daily"), w = n("weekly"), m = n("monthly"), pd = n("pdaily"), pw = n("pweekly"), pm = n("pmonthly");
        if (d != null) patch.dailyGoal = d;
        if (w != null) patch.weeklyGoal = w;
        if (m != null) patch.monthlyGoal = m;
        if (pd != null) patch.personalDaily = pd;
        if (pw != null) patch.personalWeekly = pw;
        if (pm != null) patch.personalMonthly = pm;
      }
      if (Object.keys(patch).length > 0) await ref2.set({ ...patch, updatedAt: ts() }, { merge: true });
      const cfg = (await ref2.get()).data() ?? {};
      const users = await db().collection("users").get();
      const nameOf = new Map(users.docs.map((d) => [d.id, String(d.data().name ?? d.id)]));
      const by = (cfg.personalByUid ?? {}) as Record<string, { daily?: number; weekly?: number }>;
      res.json({
        ok: true,
        командная: { день: cfg.dailyGoal ?? 50, неделя: cfg.weeklyGoal ?? 300, месяц: cfg.monthlyGoal ?? 1200 },
        личнаяВсем: { день: cfg.personalDaily ?? 10, неделя: cfg.personalWeekly ?? 60, месяц: cfg.personalMonthly ?? 250 },
        индивидуальные: Object.fromEntries(Object.entries(by).map(([u, v]) => [nameOf.get(u) ?? u, v])),
        изменено: Object.keys(patch),
      });
      return;
    }
    // Аккаунты и профили: у кого после переустановки/пересоздания разошлись
    // uid в Firebase Auth и документ users/{uid}. Без профиля не проходят
    // правила Firestore — человек «не видит лидов», хотя логин удался.
    // ?action=userslist
    if (action === "userslist") {
      const auth = await admin.auth().listUsers(100);
      const users = await db().collection("users").get();
      const profiles = new Map(users.docs.map((d) => [d.id, d.data()]));
      const rows = auth.users.map((u) => {
        const p = profiles.get(u.uid);
        return {
          email: u.email ?? "(без email)",
          uid: u.uid,
          создан: u.metadata.creationTime?.slice(5, 16) ?? null,
          последнийВход: u.metadata.lastSignInTime?.slice(5, 16) ?? null,
          профиль: p ? `${p.name ?? "?"} · ${p.role ?? "?"}${p.isActive === false ? " · ОТКЛЮЧЁН" : ""}` : "❗ НЕТ ПРОФИЛЯ",
        };
      });
      const orphanProfiles = users.docs
        .filter((d) => !auth.users.some((u) => u.uid === d.id))
        .map((d) => ({ uid: d.id, имя: d.data().name ?? "?", роль: d.data().role ?? "?" }));
      res.json({ ok: true, аккаунтов: rows.length, аккаунты: rows, профилиБезАккаунта: orphanProfiles });
      return;
    }
    // Журнал подозрительной активности: сколько событий, каких и чьих.
    // ?action=risklog&days=7
    // ?action=risklog&addcard=2204360300045901  — своя карта, не нарушение
    // ?action=risklog&delcard=...               — убрать из белого списка
    if (action === "risklog") {
      const addcard = String(req.query.addcard ?? "").replace(/\D/g, "");
      const delcard = String(req.query.delcard ?? "").replace(/\D/g, "");
      if (addcard.length >= 13) {
        await db().doc("config/risk").set(
          { allowedCards: admin.firestore.FieldValue.arrayUnion(addcard), updatedAt: ts() },
          { merge: true },
        );
      }
      if (delcard.length >= 13) {
        await db().doc("config/risk").set(
          { allowedCards: admin.firestore.FieldValue.arrayRemove(delcard), updatedAt: ts() },
          { merge: true },
        );
      }
      const days = Math.min(Math.max(Number(req.query.days ?? 7), 1), 60);
      const startTs = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86_400_000);
      // Чистка ложных тревог прошлых дней: события, где «карта»/«телефон» —
      // это цифры из ссылки 2ГИС или наша карта из белого списка.
      // ?action=risklog&purgefalse=1
      let purged = 0;
      if (String(req.query.purgefalse ?? "") === "1") {
        const cfg0 = (await db().doc("config/risk").get()).data() ?? {};
        const okCards = ((cfg0.allowedCards ?? []) as unknown[]).map((x) => String(x).replace(/\D/g, ""));
        const all = await db()
          .collection("riskEvents")
          .where("createdAt", ">=", startTs)
          .orderBy("createdAt", "desc")
          .limit(2000)
          .get();
        for (const d of all.docs) {
          const x = d.data();
          const kinds = ((x.kinds ?? []) as string[]).filter(Boolean);
          // Только card/phone-события: другие признаки (рассылка, ночь) от
          // ссылок не зависят и остаются.
          if (!kinds.every((k) => k === "card" || k === "phone" || k === "night")) continue;
          const text = String(x.text ?? "");
          const textDigits = text.replace(/\D/g, "");
          const fromUrl = /(?:https?:\/\/|www\.)\S*\d{8,}/i.test(text);
          const ownCard = okCards.some((c) => c.length >= 13 && textDigits.includes(c));
          if (fromUrl || ownCard) {
            await d.ref.delete();
            purged++;
          }
        }
      }
      const snap = await db()
        .collection("riskEvents")
        .where("createdAt", ">=", startTs)
        .orderBy("createdAt", "desc")
        .limit(300)
        .get();
      const byDay = new Map<string, number>();
      const byKind = new Map<string, number>();
      const byAuthor = new Map<string, number>();
      for (const d of snap.docs) {
        const x = d.data();
        byDay.set(String(x.day ?? "?"), (byDay.get(String(x.day ?? "?")) ?? 0) + 1);
        for (const k of (x.kinds ?? []) as string[]) byKind.set(k, (byKind.get(k) ?? 0) + 1);
        const a = String(x.authorName ?? x.authorId ?? "?");
        byAuthor.set(a, (byAuthor.get(a) ?? 0) + 1);
      }
      const cfg = (await db().doc("config/risk").get()).data() ?? {};
      res.json({
        ok: true,
        дней: days,
        удаленоЛожных: purged,
        всегоСобытий: snap.size,
        поДням: Object.fromEntries([...byDay.entries()].sort()),
        поПризнакам: Object.fromEntries([...byKind.entries()].sort((a, b) => b[1] - a[1])),
        поМенеджерам: Object.fromEntries([...byAuthor.entries()].sort((a, b) => b[1] - a[1])),
        белыйСписокКарт: cfg.allowedCards ?? [],
        белыйСписокНомеров: cfg.allowedPhones ?? [],
        последние: snap.docs.slice(0, 15).map((d) => {
          const x = d.data();
          return {
            когда: (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString().slice(0, 16) ?? null,
            кто: x.authorName ?? x.authorId,
            что: x.kinds,
            важность: x.severity,
            текст: String(x.text ?? "").slice(0, 70),
          };
        }),
      });
      return;
    }
    // Лимит темпа канала: сколько сообщений уже ушло за час и за сутки, и
    // насколько это близко к порогу. Именно упёршийся часовой лимит ставит
    // сообщения менеджеров в очередь — со стороны это выглядит как «WhatsApp
    // не даёт писать».
    //
    // ?action=limitcfg                 — показать
    // ?action=limitcfg&hour=200        — поднять часовой лимит
    // ?action=limitcfg&gap=5           — уменьшить паузу между досылками
    // ?action=limitcfg&resethour=1     — обнулить счётчик часа
    // «Человечная» задержка отправки менеджера в WhatsApp (config/wazzup):
    // сообщение уходит клиенту через случайные min…max секунд — анти-бан.
    //   ?action=wacfg              — показать
    //   ?action=wacfg&min=5&max=15 — задать (секунды)
    if (action === "wacfg") {
      const ref = db().doc("config/wazzup");
      const patch: Record<string, unknown> = {};
      const mn = Number(req.query.min ?? NaN);
      const mx = Number(req.query.max ?? NaN);
      if (Number.isFinite(mn) && mn >= 0) patch.sendDelayMinSec = Math.min(mn, 600);
      if (Number.isFinite(mx) && mx >= 0) patch.sendDelayMaxSec = Math.min(mx, 600);
      if (Object.keys(patch).length > 0) await ref.set({ ...patch, updatedAt: ts() }, { merge: true });
      const d = (await ref.get()).data() ?? {};
      res.json({
        ok: true,
        задержкаОтСек: d.sendDelayMinSec ?? "15 (по умолчанию)",
        задержкаДоСек: d.sendDelayMaxSec ?? "40 (по умолчанию)",
        изменено: Object.keys(patch).length > 0 ? patch : "ничего",
      });
      return;
    }
    if (action === "limitcfg") {
      const patch: Record<string, unknown> = {};
      const hour = Number(req.query.hour ?? NaN);
      const day = Number(req.query.day ?? NaN);
      const gap = Number(req.query.gap ?? NaN);
      if (Number.isFinite(hour)) patch.hourLimit = Math.max(10, hour);
      if (Number.isFinite(day)) patch.dayLimit = Math.max(50, day);
      if (Number.isFinite(gap)) patch.drainGapSec = Math.max(3, gap);
      if (Object.keys(patch).length > 0) {
        await db().doc("config/risk").set({ ...patch, updatedAt: ts() }, { merge: true });
      }
      // Счётчик часа хранит отметки времени отправок. Обнуляем его только по
      // явной команде: слоты, занятые снятыми из очереди сообщениями, реально
      // израсходованы не были, и без сброса канал «занят» впустую.
      if (String(req.query.resethour ?? "") === "1") {
        await db().doc("riskState/_channel").set({ sends: [], updatedAt: ts() }, { merge: true });
      }
      const cfg = (await db().doc("config/risk").get()).data() ?? {};
      const st = (await db().doc("riskState/_channel").get()).data() ?? {};
      const now = Date.now();
      const sends = ((st.sends ?? []) as unknown[]).filter(
        (t): t is number => typeof t === "number" && now - t < 3600_000,
      );
      const hourLimit = typeof cfg.hourLimit === "number" ? cfg.hourLimit : 120;
      const dayLimit = typeof cfg.dayLimit === "number" ? cfg.dayLimit : 900;
      const pending = await db().collection("outbox").where("status", "==", "pending").count().get();
      res.json({
        ok: true,
        лимитВключён: cfg.limitEnabled !== false,
        заЧас: `${sends.length} из ${hourLimit}`,
        заСутки: `${Number(st.dayCount ?? 0)} из ${dayLimit}`,
        паузаМеждуДосылкамиСек: typeof cfg.drainGapSec === "number" ? cfg.drainGapSec : 11,
        вОчереди: pending.data().count ?? 0,
        менеджерыВстаютВОчередь: sends.length >= hourLimit,
        изменено: Object.keys(patch).length > 0 ? patch : "ничего",
      });
      return;
    }
    // ЭКСТРЕННО снять из очереди автосообщения: рассылка выбирает часовой
    // лимит канала, и живые сообщения менеджеров встают в ту же очередь —
    // менеджер физически не может ответить клиенту.
    //
    // Трогаем только authorId="auto": письма менеджеров в очереди остаются.
    // Снятым чатам чистим метку дожима, иначе повторно им уже не напишешь.
    //
    // ?action=stopqueue&dry=1 — показать, сколько снимется
    // ?action=stopqueue       — снять
    // ?action=stopqueue&keep=N — оставить N ближайших по очереди автосообщений,
    //                            остальные снять («ватсап останови на 25»)
    if (action === "stopqueue") {
      const dry = String(req.query.dry ?? "") === "1";
      const keep = Math.max(0, Number(req.query.keep ?? 0) || 0);
      const snap = await db().collection("outbox").where("status", "==", "pending").limit(2000).get();
      const at = (d: FirebaseFirestore.QueryDocumentSnapshot): number =>
        (d.data().nextAttemptAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      const autoAll = snap.docs
        .filter((d) => String(d.data().authorId ?? "") === "auto")
        .sort((a, b) => at(a) - at(b));
      // Первые keep по расписанию уйдут как планировалось, снимаем хвост.
      const mine = autoAll.slice(keep);
      const managers = snap.size - autoAll.length;
      if (dry) {
        res.json({
          ok: true,
          режим: "проверка",
          вОчередиВсего: snap.size,
          снимемАвтосообщений: mine.length,
          останетсяОтМенеджеров: managers,
          примеры: mine.slice(0, 5).map((d) => ({ чат: d.data().chatId, текст: String(d.data().text ?? "").slice(0, 60) })),
        });
        return;
      }
      const freed: string[] = [];
      for (const d of mine) {
        const x = d.data();
        const chatId = String(x.chatId ?? "");
        await d.ref.delete();
        // Заглушка «часики» в переписке: сообщение так и не ушло, оставлять
        // его в чате нельзя — менеджер решит, что клиенту уже написали.
        try {
          await db().collection("messages").doc(d.id).delete();
        } catch {
          /* сообщения могло не быть — не страшно */
        }
        if (chatId) {
          await db().doc(`conversations/${chatId}`).set(
            { silentFollowUpAt: admin.firestore.FieldValue.delete() },
            { merge: true },
          );
          freed.push(chatId);
        }
      }
      const left = await db().collection("outbox").where("status", "==", "pending").count().get();
      res.json({
        ok: true,
        снято: freed.length,
        осталосьВОчереди: left.data().count ?? 0,
        меткаДожимаСнятаУ: freed.length,
        чаты: freed.slice(0, 40),
      });
      return;
    }
    // Поднять шаблоны наверх списка быстрых ответов ПРЯМО В БАЗЕ.
    //
    // Приложение сортирует шаблоны по createdAt по возрастанию, поэтому
    // «наверх» = дата создания раньше всех остальных. Так порядок меняется
    // у всех менеджеров сразу, без пересборки APK.
    //
    // ?action=qrtop            — поднять все шаблоны, названные со слова «акция»
    // ?action=qrtop&prefix=... — свой префикс названия
    // ?action=qrtop&id=<docId> — поднять один конкретный шаблон
    // ?action=qrtop&dry=1      — только показать, что будет сделано
    if (action === "qrtop") {
      const firestore = db();
      const snap = await firestore.collection("quickReplies").limit(200).get();
      const at = (d: FirebaseFirestore.QueryDocumentSnapshot): number =>
        (d.data().createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? Date.now();

      const id = String(req.query.id ?? "").trim();
      const prefix = String(req.query.prefix ?? "акция").trim().toLowerCase();
      const targets = snap.docs.filter((d) =>
        id
          ? d.id === id
          : String(d.data().title ?? "").trimStart().toLowerCase().startsWith(prefix),
      );
      if (targets.length === 0) {
        res.status(404).json({ ok: false, error: id ? "шаблон не найден" : `нет шаблонов на «${prefix}»` });
        return;
      }
      // Самая ранняя дата среди ОСТАЛЬНЫХ шаблонов — точка отсчёта.
      const others = snap.docs.filter((d) => !targets.some((t) => t.id === d.id));
      const earliest = others.length > 0 ? Math.min(...others.map(at)) : Date.now();
      // Раскладываем поднимаемые ПЕРЕД ней, сохраняя их относительный порядок.
      const ordered = [...targets].sort((a, b) => at(a) - at(b));
      const plan = ordered.map((d, i) => ({
        id: d.id,
        title: String(d.data().title ?? ""),
        было: new Date(at(d)).toISOString(),
        станет: new Date(earliest - (ordered.length - i) * 60_000).toISOString(),
      }));

      if (String(req.query.dry ?? "") === "1") {
        res.json({ ok: true, режим: "проверка", самыйРанний: new Date(earliest).toISOString(), поднимаем: plan });
        return;
      }
      for (let i = 0; i < ordered.length; i++) {
        const d = ordered[i]!;
        await d.ref.set(
          {
            createdAt: admin.firestore.Timestamp.fromMillis(earliest - (ordered.length - i) * 60_000),
            // Отметка для новой версии приложения: она сортирует по ней,
            // а не по дате. Старая версия её просто не читает.
            pinned: true,
            updatedAt: ts(),
          },
          { merge: true },
        );
      }
      // Проверка: перечитываем в том порядке, в каком их увидит приложение.
      const after = await firestore.collection("quickReplies").orderBy("createdAt").limit(200).get();
      res.json({
        ok: true,
        поднято: plan.length,
        поднимали: plan.map((p) => p.title),
        порядокПослеПравки: after.docs.slice(0, 8).map((d) => String(d.data().title ?? "")),
        всегоВидитПриложение: after.size,
        всегоВБазе: snap.size,
      });
      return;
    }
    // Пропущенные звонки WhatsApp: Wazzup присылает их как входящее
    // сообщение type=missing_call. Считаем, сколько их было и кому из
    // звонивших так никто и не ответил — это прямые потерянные пациенты.
    // ?action=misscalls&days=30
    if (action === "misscalls") {
      const days = Math.min(Math.max(Number(req.query.days ?? 30), 1), 90);
      const startTs = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86_400_000);
      // Чат → время последнего пропущенного и время ответа менеджера после него.
      const missed = new Map<string, number>();
      const byDay = new Map<string, number>();
      // Ответы менеджеров собираем одним проходом по тем же страницам.
      const replied = new Map<string, number>();
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      let scanned = 0;
      // ОТ СВЕЖИХ К СТАРЫМ: сообщений за 90 дней больше, чем успевает
      // прочитать один вызов, и при прямом порядке хвост обрезался — отчёт
      // молча заканчивался позапрошлым месяцем.
      for (let page = 0; page < 60; page++) {
        let q = db().collection("messages").where("createdAt", ">=", startTs).orderBy("createdAt", "desc").limit(1000);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        scanned += snap.size;
        for (const d of snap.docs) {
          const x = d.data();
          const chat = String(x.conversationId ?? x.chatId ?? "");
          if (!chat) continue;
          const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          if (x.direction === "inbound" && x.type === "missing_call") {
            // Держим САМЫЙ ПОЗДНИЙ звонок и самый поздний ответ: порядок
            // обхода на это влиять не должен.
            if (at > (missed.get(chat) ?? 0)) missed.set(chat, at);
            const day = new Date(at).toISOString().slice(0, 10);
            byDay.set(day, (byDay.get(day) ?? 0) + 1);
          } else if (x.direction === "outbound" && x.authorId && x.authorId !== "auto") {
            if (at > (replied.get(chat) ?? 0)) replied.set(chat, at);
          }
        }
        if (snap.size < 1000) break;
      }
      // Без ответа: после последнего пропущенного живой менеджер не написал.
      const noAnswer = [...missed.entries()]
        .filter(([chat, at]) => (replied.get(chat) ?? 0) < at)
        .map(([chat, at]) => ({ чат: chat, звонил: new Date(at).toISOString().slice(0, 16) }))
        .sort((a, b) => b.звонил.localeCompare(a.звонил));
      res.json({
        ok: true,
        дней: days,
        просмотреноСообщений: scanned,
        пропущенныхЗвонков: [...byDay.values()].reduce((a, b) => a + b, 0),
        уникальныхЗвонивших: missed.size,
        поДням: Object.fromEntries([...byDay.entries()].sort()),
        безОтветаВообще: noAnswer.length,
        примерыБезОтвета: noAnswer.slice(0, 30),
      });
      return;
    }
    // и отдельно — полный перебор. Расхождение сразу показывает, в каком
    // виде номер лежит в базе.
    // ?action=findchat&q=79899520222
    if (action === "findchat") {
      const raw = String(req.query.q ?? "").trim();
      const digits = raw.replace(/\D/g, "");
      if (raw.length < 3 && digits.length < 4) {
        res.status(400).json({ ok: false, error: "нужен q (номер или имя)" });
        return;
      }
      // Те же варианты написания, что в приложении (phoneSearchVariants).
      const variants: string[] = [];
      if (digits.length >= 4) {
        variants.push(digits);
        if (digits.startsWith("8")) variants.push(`7${digits.slice(1)}`);
        else if (!digits.startsWith("7")) variants.push(`7${digits}`);
      }
      const HI = "";
      const fast: Record<string, string[]> = {};
      for (const v of variants) {
        for (const [field, val] of [
          ["phone", v],
          ["name", `+${v}`],
        ] as const) {
          const snap = await db()
            .collection("conversations")
            .orderBy(field)
            .startAt(val)
            .endAt(`${val}${HI}`)
            .limit(20)
            .get();
          fast[`${field}~${val}`] = snap.docs.map((d) => d.id);
        }
      }
      // Полный перебор — что вообще есть в базе по этим цифрам.
      const scan: { чат: string; имя: string; телефон: string | null; тема: string | null; личный: string | null }[] = [];
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      let scanned = 0;
      for (let page = 0; page < 20; page++) {
        let q2 = db().collection("conversations").orderBy("lastMessageAt", "desc").limit(1000);
        if (cursor) q2 = q2.startAfter(cursor);
        const snap = await q2.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        scanned += snap.size;
        for (const d of snap.docs) {
          const x = d.data();
          const nameStr = String(x.name ?? "");
          const onlyDigits = `${x.phone ?? ""} ${nameStr}`.replace(/\D/g, "");
          const byPhone = variants.some((v) => onlyDigits.includes(v));
          const byName = raw.length >= 3 && nameStr.toLowerCase().includes(raw.toLowerCase());
          if (byPhone || byName) {
            scan.push({
              чат: d.id,
              имя: nameStr,
              телефон: (x.phone as string | undefined) ?? null,
              тема: (x.topic as string | undefined) ?? null,
              личный: (x.privateOwnerUid as string | undefined) ?? null,
            });
          }
        }
        if (snap.size < 1000) break;
      }
      res.json({ ok: true, запрос: raw, варианты: variants, быстрыйПоиск: fast, просмотрено: scanned, переборНашёл: scan.length, чаты: scan.slice(0, 30) });
      return;
    }
    // Удалить лид по КОНКРЕТНОМУ id (не по номеру телефона: под один номер
    // может попасть несколько записей). Требует confirm=1 — необратимо.
    // ?action=dellead&id=<docId>&confirm=1
    if (action === "dellead") {
      const id = String(req.query.id ?? "").trim();
      if (!id) {
        res.status(400).json({ ok: false, error: "нужен id" });
        return;
      }
      const ref2 = db().collection("leads").doc(id);
      const doc = await ref2.get();
      if (!doc.exists) {
        res.status(404).json({ ok: false, error: "лид не найден" });
        return;
      }
      const data = doc.data() ?? {};
      if (String(req.query.confirm ?? "") !== "1") {
        res.json({ ok: false, требуетсяПодтверждение: "добавьте confirm=1", будетУдалён: { id, имя: data.name, телефон: data.phone, номер: data.leadNumber } });
        return;
      }
      await ref2.delete();
      res.json({ ok: true, удалён: { id, имя: data.name, телефон: data.phone, номер: data.leadNumber } });
      return;
    }
    if (action === "privatechats") {
      // СКАНИРОВАНИЕМ, а не where("privateOwnerUid","!=",null): такой запрос
      // в Firestore отбрасывает документы без поля и на null ведёт себя
      // неочевидно — он показывал ноль там, где пометки реально стояли.
      const rows: { чат: string; владелец: string; последнее: string | null }[] = [];
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      let scanned = 0;
      for (let page = 0; page < 20; page++) {
        let q = db().collection("conversations").orderBy("lastMessageAt", "desc").limit(1000);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        scanned += snap.size;
        for (const d of snap.docs) {
          const owner = d.data().privateOwnerUid;
          if (typeof owner === "string" && owner.length > 0) {
            rows.push({
              чат: d.id,
              владелец: owner,
              последнее: (d.data().lastMessageAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
            });
          }
        }
        if (snap.size < 1000) break;
      }
      res.json({ ok: true, просмотрено: scanned, всего: rows.length, чаты: rows.slice(0, 50) });
      return;
    }
    if (action === "windowcheck") {
      const raw = String(req.query.phones ?? "")
        .split(/[|,\n]+/)
        .map((p) => p.replace(/\D/g, ""))
        .filter(Boolean);
      const WINDOW_MS = 24 * 3600_000;
      const now = Date.now();
      const rows: { номер: string; окно: string; последнееВходящее: string | null; часовНазад: number | null }[] = [];
      for (const digits of raw) {
        const doc = await db().doc(`conversations/${digits}`).get();
        const d = doc.data();
        const last = (d?.lastInboundAt as admin.firestore.Timestamp | undefined)?.toDate() ?? null;
        const hoursAgo = last ? (now - last.getTime()) / 3600_000 : null;
        rows.push({
          номер: `+${digits}`,
          окно: !doc.exists ? "нет чата" : last && now - last.getTime() < WINDOW_MS ? "ОТКРЫТО" : "закрыто",
          последнееВходящее: last ? last.toISOString() : null,
          часовНазад: hoursAgo !== null ? Math.round(hoursAgo * 10) / 10 : null,
        });
      }
      const open = rows.filter((r) => r.окно === "ОТКРЫТО").length;
      res.json({ ok: true, сейчас: new Date(now).toISOString(), всего: rows.length, открыто: open, закрыто: rows.length - open, список: rows });
      return;
    }
    if (action === "bookingpace") {
      const month = String(req.query.month ?? "").trim();
      const aheadDays = Math.max(1, Number(req.query.days ?? 7));
      if (!/^\d{4}-\d{2}$/.test(month)) {
        res.status(400).json({ ok: false, error: "нужен month=YYYY-MM" });
        return;
      }
      const monthStart = new Date(`${month}-01T00:00:00Z`);
      const cutoff = new Date(monthStart.getTime() - aheadDays * 86_400_000);
      const [leadsSnap, massagesSnap] = await Promise.all([
        db().collection("leads").limit(3000).get(),
        db().collection("massages").limit(3000).get(),
      ]);
      let bookedByCutoff = 0;
      let bookedTotal = 0;
      for (const d of [...leadsSnap.docs, ...massagesSnap.docs]) {
        const x = d.data();
        if (x.archived === true) continue;
        const apAt = (x.appointmentDate as admin.firestore.Timestamp | undefined)?.toDate();
        if (!apAt || apAt.toISOString().slice(0, 7) !== month) continue;
        bookedTotal++;
        const createdAt = (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate();
        if (createdAt && createdAt <= cutoff) bookedByCutoff++;
      }
      res.json({
        ok: true,
        месяц: month,
        заДнейДоНачала: aheadDays,
        порогДаты: cutoff.toISOString().slice(0, 10),
        записейБылоНаЭтотМомент: bookedByCutoff,
        записейВсегоСейчас: bookedTotal,
      });
      return;
    }
    // Сверка чеков: кому отправили реквизиты ВТБ и кто прислал чек.
    //
    // В шаблоне «ПРЕДОПЛАТА РОССИЯ» написано «отправьте чек», и клиент
    // присылает фото. Значит, чек = входящее изображение/файл ПОСЛЕ того,
    // как ушли реквизиты. Так видно и оплативших без лида (потерянные
    // деньги), и получивших реквизиты без оплаты (недожатые).
    //
    // ?action=receipts&days=5&from=2026-08-28&to=2026-08-29
    if (action === "receipts") {
      const days = Math.min(Math.max(Number(req.query.days ?? 5), 1), 60);
      const from = String(req.query.from ?? "").trim();
      const to = String(req.query.to ?? "").trim();
      const startTs = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86_400_000);
      const TZ = 5 * 3600_000;
      const dayOf = (ms: number): string => new Date(ms + TZ).toISOString().slice(0, 10);

      const norm = (p: string): string => {
        const d = String(p ?? "").replace(/\D/g, "");
        return d.length === 11 && d.startsWith("8") ? `7${d.slice(1)}` : d;
      };

      // Момент отправки реквизитов и приход чека — одним проходом.
      const sentAt = new Map<string, number>();
      const gotFile = new Map<string, { at: number; тип: string }>();
      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      let scanned = 0;
      for (let page = 0; page < 60; page++) {
        let q = db().collection("messages").where("createdAt", ">=", startTs).orderBy("createdAt", "asc").limit(1000);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        scanned += snap.size;
        for (const d of snap.docs) {
          const x = d.data();
          const chat = String(x.conversationId ?? x.chatId ?? "");
          if (!chat) continue;
          const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          if (x.direction === "outbound" && String(x.text ?? "").includes("2204")) {
            if (!sentAt.has(chat)) sentAt.set(chat, at);
          } else if (x.direction === "inbound" && ["image", "document"].includes(String(x.type ?? ""))) {
            const s = sentAt.get(chat);
            if (s != null && at >= s && !gotFile.has(chat)) gotFile.set(chat, { at, тип: String(x.type) });
          }
        }
        if (snap.size < 1000) break;
      }

      const leadsSnap = await db().collection("leads").limit(3000).get();
      const leadBy = new Map<string, FirebaseFirestore.DocumentData>();
      for (const d of leadsSnap.docs) {
        const p = norm(String(d.data().phone ?? ""));
        if (p) leadBy.set(p, d.data());
      }

      const rows0 = [...sentAt.entries()]
        .filter(([, at]) => {
          const day = dayOf(at);
          return (!from || day >= from) && (!to || day <= to);
        })
        .map(([chat, at]) => ({ chat, at }));

      // Номер телеграм-чата лежит в карточке, а не в id. Без этого все
      // телеграм-клиенты выглядели как «чек есть, лида нет» — ложная тревога
      // на ровном месте.
      const withPhones = await Promise.all(
        rows0.map(async ({ chat, at }) => {
          let phone = chat.startsWith("tg_") ? "" : norm(chat);
          if (!phone) {
            const c = (await db().doc(`conversations/${chat}`).get()).data() ?? {};
            phone = norm(String(c.phone ?? ""));
          }
          const lead = phone ? leadBy.get(phone) : undefined;
          const f = gotFile.get(chat);
          return {
            чат: chat,
            телефон: phone || "(нет номера)",
            реквизитыОтправлены: new Date(at + TZ).toISOString().slice(0, 16).replace("T", " "),
            чекПрислан: f ? new Date(f.at + TZ).toISOString().slice(0, 16).replace("T", " ") : null,
            лид: lead
              ? `№${lead.leadNumber ?? "?"} ${lead.name ?? ""} · ${lead.prepayment ?? "нет"} ${lead.currency ?? ""}${lead.archived === true ? " · В АРХИВЕ" : ""}`
              : null,
          };
        }),
      );
      const rows = withPhones.sort((a, b) => a.реквизитыОтправлены.localeCompare(b.реквизитыОтправлены));

      const чекБезЛида = rows.filter((r) => r.чекПрислан && !r.лид);
      res.json({
        ok: true,
        просмотреноСообщений: scanned,
        период: `${from || "—"} … ${to || "—"}`,
        получилиРеквизиты: rows.length,
        прислалиЧек: rows.filter((r) => r.чекПрислан).length,
        чекЕстьЛидаНЕТ: чекБезЛида.length,
        ПОТЕРЯННЫЕ_ЧЕКИ: чекБезЛида,
        все: rows,
      });
      return;
    }
    // Все российские (и вообще иногородние) пациенты за период — по ТРЁМ
    // признакам, а не только по номеру телефона:
    //   1) номер не казахстанский;
    //   2) клиент сам написал про Россию / гражданство РФ;
    //   3) мы отправили ему «российский» шаблон — прайс для других стран,
    //      предоплата в рублях, расписание и акция для России.
    //
    // Номер ловит не всех: россиянин часто пишет с казахстанской симки или из
    // Telegram без номера вовсе, а платит всё равно в рублях.
    //
    // ?action=ruleads&days=7
    if (action === "ruleads") {
      const days = Math.min(Math.max(Number(req.query.days ?? 7), 1), 60);
      const startTs = admin.firestore.Timestamp.fromMillis(Date.now() - days * 86_400_000);

      const norm = (p: string): string => {
        const d = String(p ?? "").replace(/\D/g, "");
        return d.length === 11 && d.startsWith("8") ? `7${d.slice(1)}` : d;
      };
      const isKz = (d: string): boolean => d.startsWith("7") && (d[1] === "6" || d[1] === "7");

      // Лиды по номеру — чтобы сразу видеть предоплату и её валюту.
      const leadsSnap = await db().collection("leads").limit(3000).get();
      const leadBy = new Map<string, FirebaseFirestore.DocumentData>();
      for (const d of leadsSnap.docs) {
        const p = norm(String(d.data().phone ?? ""));
        if (p) leadBy.set(p, { id: d.id, ...d.data() });
      }

      const RU_IN = ["росси", "рассия", "рф ", " рф", "москв", "питер", "спб"];
      const RU_OUT = [
        "для россии",
        "россия информация",
        "предоплата россия",
        "акция россия",
        "расписание россия",
        "для пациентов из других стран",
        "других городов и стран",
        "6 000 ₽",
        "6000 ₽",
        "12 000 ₽",
      ];
      type Hit = { поНомеру: boolean; словаКлиента: string | null; нашШаблон: string | null };
      const hits = new Map<string, Hit>();

      let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
      let scanned = 0;
      for (let page = 0; page < 60; page++) {
        let q = db().collection("messages").where("createdAt", ">=", startTs).orderBy("createdAt", "desc").limit(1000);
        if (cursor) q = q.startAfter(cursor);
        const snap = await q.get();
        if (snap.empty) break;
        cursor = snap.docs[snap.docs.length - 1] ?? null;
        scanned += snap.size;
        for (const d of snap.docs) {
          const x = d.data();
          const chat = String(x.conversationId ?? x.chatId ?? "");
          if (!chat) continue;
          const text = String(x.text ?? "").toLowerCase();
          if (!text) continue;
          const cur = hits.get(chat) ?? { поНомеру: false, словаКлиента: null, нашШаблон: null };
          if (x.direction === "inbound") {
            const w = RU_IN.find((k) => text.includes(k));
            if (w && !cur.словаКлиента) cur.словаКлиента = String(x.text ?? "").slice(0, 70);
          } else {
            const w = RU_OUT.find((k) => text.includes(k));
            if (w && !cur.нашШаблон) cur.нашШаблон = w;
          }
          if (cur.словаКлиента || cur.нашШаблон) hits.set(chat, cur);
        }
        if (snap.size < 1000) break;
      }

      // Номер чата: у WhatsApp это сам id, у Telegram — поле phone.
      const rows: Record<string, unknown>[] = [];
      for (const [chat, h] of hits) {
        const convDoc = await db().doc(`conversations/${chat}`).get();
        const c = convDoc.data() ?? {};
        const phone = norm(String(c.phone ?? (chat.startsWith("tg_") ? "" : chat)));
        const byNumber = phone.length > 0 && !isKz(phone);
        const lead = phone ? leadBy.get(phone) : undefined;
        rows.push({
          чат: chat,
          имя: String(c.name ?? chat),
          телефон: phone || "(номер не известен)",
          признаки: [byNumber ? "номер" : null, h.словаКлиента ? "слова клиента" : null, h.нашШаблон ? "наш шаблон" : null].filter(Boolean),
          словаКлиента: h.словаКлиента,
          нашШаблон: h.нашШаблон,
          лид: lead ? { номер: lead.leadNumber ?? null, имя: lead.name ?? null, предоплата: lead.prepayment ?? null, валюта: lead.currency ?? null, архив: lead.archived === true } : null,
        });
      }
      rows.sort((a, b) => ((b.признаки as string[]).length - (a.признаки as string[]).length));
      const сЛидом = rows.filter((r) => r.лид != null);
      res.json({
        ok: true,
        дней: days,
        просмотреноСообщений: scanned,
        найденоЧатов: rows.length,
        изНихСталиЛидами: сЛидом.length,
        безПредоплаты: сЛидом.filter((r) => (r.лид as { предоплата: unknown }).предоплата == null).length,
        чаты: rows.slice(0, 80),
      });
      return;
    }
    // Переписать автора лида на другого менеджера.
    //
    // Соревнование менеджеров и статистика считаются по leads.createdBy, так
    // что это меняет зачёт. Прежний автор сохраняется в createdByPrev —
    // чтобы можно было вернуть, если передали не тому.
    //
    // Правило автопередачи лидов (config/leads.autoOwner): всё, что заводит
    // from, сразу записывается на to. Срабатывает триггер onLeadCreated.
    //   ?action=leadauto                    — показать правило
    //   ?action=leadauto&from=Нурс&to=Тима  — включить / сменить
    //   ?action=leadauto&off=1              — выключить (правило остаётся)
    if (action === "leadauto") {
      const users = await db().collection("users").limit(100).get();
      const nameOf = new Map(users.docs.map((d) => [d.id, String(d.data().name ?? "").trim() || d.id]));
      const uidOf = (s: string): string | null => {
        const q = s.trim().toLowerCase();
        if (!q) return null;
        if (nameOf.has(s.trim())) return s.trim();
        for (const [uid, name] of nameOf) if (name.toLowerCase() === q) return uid;
        for (const [uid, name] of nameOf) if (name.toLowerCase().includes(q)) return uid;
        return null;
      };
      const ref = db().doc("config/leads");
      const fromQ = String(req.query.from ?? "").trim();
      const toQ = String(req.query.to ?? "").trim();
      if (fromQ || toQ) {
        const from = uidOf(fromQ);
        const to = uidOf(toQ);
        if (!from || !to) {
          res.status(400).json({ ok: false, error: "нужны from и to (имя или uid)", естьМенеджеры: [...nameOf.values()] });
          return;
        }
        await ref.set({ autoOwner: { from, to, enabled: true, updatedAt: ts() } }, { merge: true });
      } else if (String(req.query.off ?? "") === "1") {
        await ref.set({ autoOwner: { enabled: false, updatedAt: ts() } }, { merge: true });
      }
      const r = ((await ref.get()).data() ?? {}).autoOwner as Record<string, unknown> | undefined;
      res.json({
        ok: true,
        правило: r
          ? {
              включено: r.enabled !== false,
              лидыОт: nameOf.get(String(r.from ?? "")) ?? r.from ?? null,
              записываютсяНа: nameOf.get(String(r.to ?? "")) ?? r.to ?? null,
            }
          : "не задано",
      });
      return;
    }
    // ?action=leadowner&from=Тима&to=admin&date=2026-08-30&dry=1
    // ?action=leadowner&ids=<docId>,<docId>&to=admin
    if (action === "leadowner") {
      const TZ = 5 * 3600_000;
      const users = await db().collection("users").limit(100).get();
      const nameOf = new Map(users.docs.map((d) => [d.id, String(d.data().name ?? "").trim() || d.id]));
      /** Имя менеджера или uid → uid. */
      const uidOf = (s: string): string | null => {
        const q = s.trim().toLowerCase();
        if (!q) return null;
        if (nameOf.has(s.trim())) return s.trim();
        for (const [uid, name] of nameOf) if (name.toLowerCase() === q) return uid;
        for (const [uid, name] of nameOf) if (name.toLowerCase().includes(q)) return uid;
        return null;
      };

      const toUid = uidOf(String(req.query.to ?? ""));
      if (!toUid) {
        res.status(400).json({ ok: false, error: "не нашёл менеджера to", естьМенеджеры: [...nameOf.values()] });
        return;
      }
      const ids = String(req.query.ids ?? "").split(",").map((s) => s.trim()).filter(Boolean);
      let docs: FirebaseFirestore.QueryDocumentSnapshot[];
      if (ids.length > 0) {
        const got = await Promise.all(ids.map((i) => db().collection("leads").doc(i).get()));
        docs = got.filter((g) => g.exists) as unknown as FirebaseFirestore.QueryDocumentSnapshot[];
      } else {
        const fromUid = uidOf(String(req.query.from ?? ""));
        if (!fromUid) {
          res.status(400).json({ ok: false, error: "нужен from (менеджер) или ids", естьМенеджеры: [...nameOf.values()] });
          return;
        }
        const dateStr = String(req.query.date ?? "").trim();
        const dayStart = (() => {
          if (/^\d{4}-\d{2}-\d{2}$/.test(dateStr)) {
            const [y, m, dd] = dateStr.split("-").map(Number);
            return Date.UTC(y!, m! - 1, dd!) - TZ;
          }
          const l = new Date(Date.now() + TZ);
          return Date.UTC(l.getUTCFullYear(), l.getUTCMonth(), l.getUTCDate()) - TZ;
        })();
        const snap = await db()
          .collection("leads")
          .where("createdAt", ">=", admin.firestore.Timestamp.fromMillis(dayStart))
          .where("createdAt", "<", admin.firestore.Timestamp.fromMillis(dayStart + 86_400_000))
          .get();
        docs = snap.docs.filter((d) => String(d.data().createdBy ?? "") === fromUid);
      }

      const plan = docs.map((d) => {
        const x = d.data();
        const prev = String(x.createdBy ?? "");
        return {
          id: d.id,
          номер: (x.leadNumber as number | undefined) ?? null,
          имя: String(x.name ?? ""),
          телефон: String(x.phone ?? ""),
          было: nameOf.get(prev) ?? prev,
          станет: nameOf.get(toUid) ?? toUid,
        };
      });
      if (String(req.query.dry ?? "") === "1") {
        res.json({ ok: true, режим: "проверка", найдено: plan.length, лиды: plan });
        return;
      }
      for (const d of docs) {
        const prev = String(d.data().createdBy ?? "");
        await d.ref.set(
          { createdBy: toUid, createdByPrev: prev, ownerChangedAt: ts() },
          { merge: true },
        );
      }
      res.json({ ok: true, переписано: plan.length, лиды: plan });
      return;
    }
    // Лиды за день с именем менеджера, который их завёл.
    // ?action=leadsby           — сегодня, все менеджеры
    // ?action=leadsby&who=Тима  — только этот менеджер
    // ?action=leadsby&date=2026-08-29
    if (action === "leadsby") {
      const TZ = 5 * 3600_000; // Астана
      const dateStr = String(req.query.date ?? "").trim();
      const dayStart = (() => {
        if (/^\d{4}-\d{2}-\d{2}$/.test(dateStr)) {
          const [y, m, dd] = dateStr.split("-").map(Number);
          return Date.UTC(y!, m! - 1, dd!) - TZ;
        }
        const l = new Date(Date.now() + TZ);
        return Date.UTC(l.getUTCFullYear(), l.getUTCMonth(), l.getUTCDate()) - TZ;
      })();
      const dayEnd = dayStart + 86_400_000;

      const users = await db().collection("users").limit(100).get();
      const nameOf = new Map(users.docs.map((d) => [d.id, String(d.data().name ?? "").trim() || d.id]));

      const snap = await db()
        .collection("leads")
        .where("createdAt", ">=", admin.firestore.Timestamp.fromMillis(dayStart))
        .where("createdAt", "<", admin.firestore.Timestamp.fromMillis(dayEnd))
        .get();

      const who = String(req.query.who ?? "").trim().toLowerCase();
      const rows = snap.docs
        .map((d) => {
          const x = d.data();
          const uid = String(x.createdBy ?? "");
          const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
          const appt = (x.appointmentDate as admin.firestore.Timestamp | undefined)?.toDate();
          return {
            менеджер: nameOf.get(uid) ?? (uid ? `uid ${uid.slice(0, 8)}` : "неизвестно"),
            uid,
            номер: (x.leadNumber as number | undefined) ?? null,
            имя: String(x.name ?? ""),
            телефон: String(x.phone ?? ""),
            приём: appt ? appt.toISOString().slice(0, 10) : null,
            время: (x.appointmentTime as string | undefined) ?? null,
            предоплата: (x.prepayment as number | undefined) ?? null,
            валюта: (x.currency as string | undefined) ?? null,
            архив: x.archived === true,
            заведён: new Date(at + TZ).toISOString().slice(11, 16), // по Астане
          };
        })
        .filter((r) => !who || r.менеджер.toLowerCase().includes(who))
        .sort((a, b) => a.заведён.localeCompare(b.заведён));

      const byMgr = new Map<string, number>();
      for (const r of rows) byMgr.set(r.менеджер, (byMgr.get(r.менеджер) ?? 0) + 1);

      res.json({
        ok: true,
        день: new Date(dayStart + TZ).toISOString().slice(0, 10),
        всегоЗаДень: snap.size,
        показано: rows.length,
        поМенеджерам: Object.fromEntries([...byMgr.entries()].sort((a, b) => b[1] - a[1])),
        лиды: rows,
      });
      return;
    }
    if (action === "leadshist") {
      const snap = await db().collection("leads").limit(3000).get();
      const byDay = new Map<string, number>();
      let archived = 0;
      for (const d of snap.docs) {
        const x = d.data();
        if (x.archived === true) archived++;
        const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate();
        const day = at ? at.toISOString().slice(0, 10) : "без даты";
        byDay.set(day, (byDay.get(day) ?? 0) + 1);
      }
      res.json({ ok: true, всего: snap.size, архивных: archived, поДням: Object.fromEntries([...byDay.entries()].sort()) });
      return;
    }
    if (action === "checkcreatetime") {
      // Проверка гипотезы: doc.createTime документа conversations — это
      // ДЕЙСТВИТЕЛЬНО момент первого сообщения, а не дата какой-то массовой
      // перезаписи (например, миграции)? Берём самые старые по переписке
      // чаты (по первому сообщению в messages) и сверяем с createTime.
      const oldest = await db().collection("messages").orderBy("createdAt", "asc").limit(15).get();
      const seen = new Set<string>();
      const rows: { chat: string; первоеСообщение: string; createTimeЧата: string | null; расхождениеДней: number | null }[] = [];
      for (const d of oldest.docs) {
        const x = d.data();
        const cid = String(x.conversationId ?? x.chatId ?? "");
        if (!cid || seen.has(cid)) continue;
        seen.add(cid);
        const msgAt = (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate();
        const convDoc = await db().doc(`conversations/${cid}`).get();
        const ct = convDoc.exists ? convDoc.createTime?.toDate() ?? null : null;
        rows.push({
          chat: cid,
          первоеСообщение: msgAt?.toISOString() ?? "?",
          createTimeЧата: ct?.toISOString() ?? null,
          расхождениеДней: msgAt && ct ? Math.round((ct.getTime() - msgAt.getTime()) / 86_400_000) : null,
        });
      }
      res.json({ ok: true, rows });
      return;
    }
    if (action === "doctimehist") {
      // Гистограмма createTime по чатам — проверка, не искажена ли она
      // массовым созданием документов (миграция и т.п.), а не реальной датой
      // первого обращения.
      const snap = await db().collection("conversations").orderBy("lastMessageAt", "desc").limit(500).get();
      const byDay = new Map<string, number>();
      for (const d of snap.docs) {
        const day = d.createTime.toDate().toISOString().slice(0, 10);
        byDay.set(day, (byDay.get(day) ?? 0) + 1);
      }
      res.json({ ok: true, всегоПроверено: snap.size, поДнямСозданияДокумента: Object.fromEntries([...byDay.entries()].sort()) });
      return;
    }
    if (action === "doctime") {
      const id = String(req.query.id ?? "").trim();
      const d = await db().doc(`conversations/${id}`).get();
      res.json({ ok: true, exists: d.exists, createTime: d.createTime?.toDate().toISOString() ?? null, updateTime: d.updateTime?.toDate().toISOString() ?? null });
      return;
    }
    if (action === "convstats") {
      const days = Math.min(Math.max(Number(req.query.days ?? 30), 1), 90);
      try {
        res.json({ ok: true, ...(await computeConversionStats(days)) });
      } catch (e) {
        res.json({ ok: false, ошибка: String(e instanceof Error ? e.message : e) });
      }
      return;
    }
    if (action === "convstatsmgr") {
      const days = Math.min(Math.max(Number(req.query.days ?? 30), 1), 90);
      try {
        res.json({ ok: true, ...(await computeManagerStats(days)) });
      } catch (e) {
        res.json({ ok: false, ошибка: String(e instanceof Error ? e.message : e) });
      }
      return;
    }
    if (action === "autoall") {
      // ?action=autoall&off=1 / &on=1        — оба канала разом
      // ?action=autoall&tg=1 / &tg=0         — только Telegram (приветствие /start и т.п.)
      // ?action=autoall&wa=1 / &wa=0         — только WhatsApp (автоответ первому обращению)
      const patch: Record<string, unknown> = {};
      const off = String(req.query.off ?? "") === "1";
      const on = String(req.query.on ?? "") === "1";
      if (on || off) {
        patch.telegram = on;
        patch.whatsapp = on;
      }
      if (String(req.query.tg ?? "") === "1") patch.telegram = true;
      if (String(req.query.tg ?? "") === "0") patch.telegram = false;
      if (String(req.query.wa ?? "") === "1") patch.whatsapp = true;
      if (String(req.query.wa ?? "") === "0") patch.whatsapp = false;
      if (Object.keys(patch).length > 0) {
        await db().doc("config/autoMessages").set({ ...patch, updatedAt: ts() }, { merge: true });
        if (off) {
          // «Выключить всё» разом гасит и ИИ-ботов с догревом — не только
          // заготовленные тексты. Точечный tg=/wa= их не трогает.
          for (const [doc, p] of [
            ["config/aiReply", { enabled: false }],
            ["config/trainingReply", { enabled: false }],
            ["config/followUp", { enabled: false }],
          ] as const) {
            await db().doc(doc).set({ ...p, updatedAt: ts() }, { merge: true });
          }
        }
      }
      const read = async (p: string) => (await db().doc(p).get()).data() ?? {};
      const [ai, tr, fu, vac, wa] = await Promise.all([
        read("config/aiReply"),
        read("config/trainingReply"),
        read("config/followUp"),
        read("config/vacationReply"),
        read("config/waAutoReply"),
      ]);
      // Свои варианты в базе ПЕРЕКРЫВАЮТ тексты из кода — если они есть,
      // правка исходников на клиенте не отразится.
      const waCustom = Array.isArray(wa.variants) ? wa.variants.length : 0;
      res.json({
        ok: true,
        приветствиеTelegram: (await telegramAutoMessagesOn()) ? "включено" : "выключено",
        waAutoReplyEnabled: wa.enabled === true,
        waСвоихВариантовВБазе: waCustom,
        автоответWhatsApp: (await whatsappAutoMessagesOn()) ? "включено" : "выключено",
        пациентскийИИ: ai.enabled === true ? "включён" : "выключен",
        ботОбучение: tr.enabled === true ? "включён" : "выключен",
        догрев: fu.enabled === false ? "выключен" : "включён",
        отпуск: vac.enabled === true ? "включён" : "выключен",
      });
      return;
    }
    if (action === "aimodels") {
      try {
        const r = await fetch("https://api.anthropic.com/v1/models?limit=100", {
          headers: { "x-api-key": ANTHROPIC_API_KEY.value(), "anthropic-version": "2023-06-01" },
        });
        const j = await r.json();
        res.json({ ok: r.ok, status: r.status, data: j });
      } catch (e) {
        res.json({ ok: false, ошибка: String(e instanceof Error ? e.message : e) });
      }
      return;
    }

    // Вечерняя сводка руководству: предпросмотр, отправка, настройка.
    //   ?action=report                     — показать текст за сегодня
    //   ?action=report&send=1              — отправить получателям сейчас
    //   ?action=report&chat=<tg id>        — отправить только этому чату (тест)
    //   ?action=reportcfg&chats=<id>|<id>  — задать получателей
    //   ?action=reportcfg&off=1 / &on=1    — выключить/включить
    if (action === "report") {
      const startMs = reportDayStartMs(Date.now());
      const text = await buildDailyReport(startMs);
      const testChat = String(req.query.chat ?? "").replace(/^tg_/, "").trim();
      const doSend = String(req.query.send ?? "") === "1" || testChat !== "";
      let result: { sent: string[]; failed: string[] } | null = null;
      if (doSend) {
        const rcpt = testChat !== "" ? [testChat] : (await reportRecipients()).chatIds;
        result = await sendReport(token, rcpt, text);
      }
      res.json({ ok: true, текст: text, ...(result ? { отправлено: result.sent, неДошло: result.failed } : {}) });
      return;
    }

    if (action === "reportcfg") {
      const patch: Record<string, unknown> = { updatedAt: ts() };
      const chats = String(req.query.chats ?? "")
        .split("|")
        .map((s) => s.replace(/^tg_/, "").trim())
        .filter((s) => /^\d+$/.test(s));
      if (chats.length > 0) patch.chatIds = chats;
      if (String(req.query.off ?? "") === "1") patch.enabled = false;
      if (String(req.query.on ?? "") === "1") patch.enabled = true;
      await db().doc("config/dailyReport").set(patch, { merge: true });
      res.json({ ok: true, конфиг: (await db().doc("config/dailyReport").get()).data() });
      return;
    }

    // Разовый ремонт старых голосовых Telegram: OGG/Opus не играет на iPhone,
    // перекодируем лежащие в Storage файлы в MP3 и обновляем ссылки в
    // сообщениях. ?action=fixvoices[&limit=50]
    if (action === "fixvoices") {
      const firestore = db();
      const lim = Math.min(Number(req.query.limit ?? 50) || 50, 200);
      const snap = await firestore.collection("messages").orderBy("createdAt", "desc").limit(2000).get();
      const bucket = admin.storage().bucket();
      let fixed = 0;
      const errors: string[] = [];
      for (const doc of snap.docs) {
        if (fixed >= lim) break;
        const d = doc.data();
        if (d.type !== "audio" || !String(doc.id).startsWith("tg_")) continue;
        if (!/ogg|opus/i.test(String(d.mediaContentType ?? ""))) continue;
        const path = `media/tg/in/${doc.id}`;
        try {
          if (!(await bucket.file(path).exists())[0]) continue;
          const mp3 = await toWhatsAppAudio(path);
          if (!mp3) continue;
          const tok = randomUUID();
          await bucket.file(mp3).setMetadata({ metadata: { firebaseStorageDownloadTokens: tok } });
          const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(mp3)}?alt=media&token=${tok}`;
          await doc.ref.set({ mediaUrl: url, mediaContentType: "audio/mpeg" }, { merge: true });
          fixed++;
        } catch (e) {
          errors.push(`${doc.id}: ${String(e instanceof Error ? e.message : e).slice(0, 80)}`);
        }
      }
      res.json({ ok: true, перекодировано: fixed, ошибки: errors.slice(0, 10) });
      return;
    }

    // Разовый ремонт подписи «ответил …» в списке чатов: эхо Wazzup перетёрло
    // менеджера именем аккаунта («Admin»). Берём автора из последнего
    // исходящего сообщения переписки. ?action=fixauthors[&dry=1]
    if (action === "fixauthors") {
      const firestore = db();
      const dry = String(req.query.dry ?? "") === "1";
      const snap = await firestore
        .collection("conversations")
        .orderBy("lastMessageAt", "desc")
        .limit(500)
        .get();
      const fixed: Record<string, unknown>[] = [];
      for (const doc of snap.docs) {
        const d = doc.data();
        if (d.lastOutbound !== true) continue;
        if (!d.lastAuthorName || d.lastAuthorId) continue; // нечего чинить
        const last = await firestore
          .collection("messages")
          .where("conversationId", "==", doc.id)
          .orderBy("createdAt", "desc")
          .limit(5)
          .get();
        const out = last.docs.map((x) => x.data()).find((x) => x.direction === "outbound");
        const author = String(out?.authorId ?? "");
        if (!author) continue; // реально отправлено из интерфейса Wazzup
        fixed.push({ чат: doc.id, было: d.lastAuthorName, стало: author });
        if (!dry) {
          await doc.ref.set({ lastAuthorId: author, lastAuthorName: null, updatedAt: ts() }, { merge: true });
        }
      }
      res.json({ ok: true, проверено: snap.size, исправлено: fixed.length, пробныйЗапуск: dry, список: fixed.slice(0, 50) });
      return;
    }

    // Кто прислал файл за последние N часов. Нужен, когда пациенты шлют
    // снимки и заключения: ищем по типу вложения, а не по тексту.
    //   ?action=files[&hours=3][&ext=pdf][&country=ru|kz]
    if (action === "files") {
      const firestore = db();
      const hours = Math.min(Math.max(Number(req.query.hours ?? 3) || 3, 1), 72);
      const ext = String(req.query.ext ?? "pdf").trim().toLowerCase();
      const country = String(req.query.country ?? "").trim().toLowerCase();
      const since = Date.now() - hours * 3600_000;

      // Без where по типу: составной индекс не нужен, свежих сообщений мало.
      const snap = await firestore.collection("messages").orderBy("createdAt", "desc").limit(2000).get();
      const out: Record<string, unknown>[] = [];
      const seen = new Set<string>();
      for (const d of snap.docs) {
        const x = d.data();
        const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate();
        if (!at || at.getTime() < since) break; // дальше только старее
        if (x.direction !== "inbound") continue;
        const name = String(x.fileName ?? "").toLowerCase();
        const mime = String(x.mediaContentType ?? "").toLowerCase();
        const uri = String(x.mediaUrl ?? x.contentUri ?? "").toLowerCase();
        const isFile = x.type === "document" || x.type === "file" || name !== "" || mime !== "";
        const hitExt = ext === "" || name.endsWith(`.${ext}`) || mime.includes(ext) || uri.includes(`.${ext}`);
        if (!isFile || !hitExt) continue;
        const chat = String(x.conversationId ?? x.chatId ?? "");
        const phone = chat.replace(/\D/g, "");
        // Российские номера — 79…, казахстанские — 77…
        const cc = phone.startsWith("79") ? "ru" : phone.startsWith("77") ? "kz" : "other";
        if (country && cc !== country) continue;
        const key = `${chat}|${d.id}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({
          номер: phone ? `+${phone}` : chat,
          страна: cc,
          файл: x.fileName ?? null,
          тип: x.mediaContentType ?? x.type ?? null,
          когда: at.toISOString(),
          чат: chat,
        });
      }
      const numbers = [...new Set(out.map((r) => r["номер"] as string))];
      res.json({ ok: true, часов: hours, расширение: ext, страна: country || "любая", номера: numbers, файлов: out.length, список: out });
      return;
    }

    // Правила тем (обучение / БАДы): посмотреть, проверить текст и дописать
    // фразы БЕЗ деплоя — они лежат в config/topics.
    //   ?action=topics
    //   ?action=topics&test=<текст сообщения>
    //   ?action=topics&addbad=<фраза>|<фраза>   — дописать
    //   ?action=topics&setbad=<фраза>|<фраза>   — заменить список целиком
    if (action === "topics") {
      const firestore = db();
      const cfgRef = firestore.doc("config/topics");
      const parse = (v: unknown) =>
        String(v ?? "")
          .split("|")
          .map((s) => normalizeTopicText(s))
          .filter((s) => s.length >= 3);

      const setBad = parse(req.query.setbad);
      const addBad = parse(req.query.addbad);
      if (setBad.length > 0 || addBad.length > 0) {
        const cur = ((await cfgRef.get()).data()?.supplementPhrases ?? []) as unknown[];
        const next =
          setBad.length > 0
            ? setBad
            : [...new Set([...cur.map((p) => normalizeTopicText(String(p))), ...addBad])].filter((p) => p.length >= 3);
        await cfgRef.set({ supplementPhrases: next, updatedAt: ts() }, { merge: true });
      }

      // Кэш правил живёт 5 минут в каждом инстансе — правки видны не сразу.
      const rules = await topicRules();
      const test = String(req.query.test ?? "");
      res.json({
        ok: true,
        обучение_корни: rules.training,
        бады_фразы: rules.supplements,
        звонок_корни: rules.call,
        подсказка:
          "Обучение и звонок ищутся корнем слова (ловит и опечатки в окончании), БАДы — фраза из нескольких слов куском текста, из одного слова — целым словом. " +
          "Регистр, «ё» и знаки препинания значения не имеют, казахские буквы сохраняются. Новые правила подхватятся в течение 5 минут.",
        ...(test
          ? { проверка: { текст: test, вид: normalizeAnyScript(test), тема: (await detectTopic(test)) ?? "нет" } }
          : {}),
        ...(setBad.length > 0 || addBad.length > 0 ? { записано: true } : {}),
      });
      return;
    }

    // Добавить быстрый ответ прямо в базу (владелец диктует текст в чат, а не
    // набирает на телефоне). Тот же документ, что создаёт приложение:
    // варианты для анти-бана подготовит триггер onQuickReplyWritten.
    //   ?action=qradd&title=Массаж&text=...   (&pinned=1 — закрепить наверху)
    if (action === "qradd") {
      const title = String(req.query.title ?? "").trim();
      const text = String(req.query.text ?? "").trim();
      if (!title || !text) {
        res.status(400).json({ ok: false, error: "нужны title и text" });
        return;
      }
      const dup = (await db().collection("quickReplies").where("title", "==", title).limit(1).get()).docs[0];
      if (dup) {
        res.json({ ok: false, error: "шаблон с таким названием уже есть", id: dup.id });
        return;
      }
      const ref = await db().collection("quickReplies").add({
        title,
        text,
        ...(String(req.query.pinned ?? "") === "1" ? { pinned: true } : {}),
        createdAt: ts(),
      });
      res.json({ ok: true, id: ref.id, title, символов: text.length });
      return;
    }
    // Шаблоны быстрых ответов: текст, отпечатки (точный и старый «без цифр»)
    // и число вариантов. Нужен, чтобы видеть столкновения шаблонов. ?action=qr
    if (action === "qr") {
      const firestore = db();
      const snap = await firestore.collection("quickReplies").limit(200).get();
      res.json({
        ok: true,
        items: snap.docs.map((d) => {
          const x = d.data();
          const text = String(x.text ?? "");
          return {
            id: d.id,
            title: String(x.title ?? ""),
            text,
            exact: exactFingerprint(text),
            loose: fingerprint(text),
            variantsFor: x.variantsFor ?? null,
            variants: ((x.variants ?? []) as unknown[]).length,
          };
        }),
      });
      return;
    }

    // Разово заполнить варианты уже сохранённым быстрым ответам (дальше их
    // готовит триггер onQuickReplyWritten). ?action=seedvariants
    if (action === "seedvariants") {
      const firestore = db();
      const snap = await firestore.collection("quickReplies").limit(200).get();
      const done: { id: string; title: string; variants: number }[] = [];
      for (const doc of snap.docs) {
        const text = String(doc.data().text ?? "").trim();
        if (!text) continue;
        const variants = makeVariants(text, 6);
        await doc.ref.set({ variants, variantsFor: exactFingerprint(text), variantsAt: ts() }, { merge: true });
        done.push({ id: doc.id, title: String(doc.data().title ?? "").slice(0, 60), variants: variants.length });
      }
      res.json({ ok: true, quickReplies: snap.size, seeded: done });
      return;
    }

    // Журналы удалённой диагностики с устройств менеджеров (clientLogs/{uid}):
    // ошибки, зависшие кадры, мигание клавиатуры. ?action=clientlogs
    if (action === "clientlogs") {
      const firestore = db();
      const snap = await firestore.collection("clientLogs").get();
      const users = await firestore.collection("users").get();
      const names = new Map(users.docs.map((d) => [d.id, String(d.data().name ?? "")]));
      res.json({
        ok: true,
        devices: snap.docs.map((d) => ({
          uid: d.id,
          name: names.get(d.id) ?? "",
          os: d.data().os ?? "",
          updatedAt: (d.data().updatedAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
          lines: ((d.data().lines ?? []) as unknown[]).slice(-60),
        })),
      });
      return;
    }

    // Поиск номера по переписке: в каком Telegram-чате он упоминался и что
    // сейчас в карточке этого чата. ?action=findphone&q=79872866844
    if (action === "findphone") {
      const q = String(req.query.q ?? "").replace(/\D/g, "");
      if (q.length < 6) {
        res.json({ ok: false, error: "q: минимум 6 цифр" });
        return;
      }
      const firestore = db();
      const msgs = await firestore
        .collection("messages")
        .where("conversationId", ">=", "tg_")
        .where("conversationId", "<", "tg`")
        .limit(2000)
        .get();
      const hits: Record<string, unknown>[] = [];
      const convIds = new Set<string>();
      for (const m of msgs.docs) {
        const x = m.data();
        const digits = String(x.text ?? "").replace(/\D/g, "");
        if (!digits.includes(q)) continue;
        convIds.add(String(x.conversationId ?? ""));
        hits.push({
          conversationId: x.conversationId,
          direction: x.direction,
          text: String(x.text ?? "").slice(0, 120),
          at: (x.createdAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() ?? null,
        });
      }
      const cards: Record<string, unknown>[] = [];
      for (const id of convIds) {
        const c = (await firestore.doc(`contacts/${id}`).get()).data() ?? {};
        cards.push({ id, name: c.name, phone: c.phone, phoneSource: c.phoneSource, username: c.username });
      }
      // И по полю phone в карточках: туда номер попадает через кнопку
      // «Поделиться номером» — в тексте сообщений его может не быть.
      const byPhone = await firestore.collection("contacts").where("phone", "==", q).limit(10).get();
      for (const d of byPhone.docs) {
        const c = d.data();
        cards.push({ id: d.id, name: c.name, phone: c.phone, phoneSource: c.phoneSource, username: c.username });
      }
      res.json({ ok: true, scannedMessages: msgs.size, hits, cards });
      return;
    }

    // Диагностика: бот, вебхук, очередь ретраев, последние апдейты.
    const me = await tgCall<Record<string, unknown>>(token, "getMe", {}).catch((e) => ({ error: String(e) }));
    const info = await tgCall<Record<string, unknown>>(token, "getWebhookInfo", {}).catch((e) => ({ error: String(e) }));
    const firestore = db();
    const pending = await firestore.collection("tgOutbox").where("status", "==", "pending").limit(50).get();
    const failed = await firestore.collection("tgOutbox").where("status", "==", "failed").limit(5).get();
    const errors = await firestore.collection("tgUpdates").where("status", "==", "error").limit(5).get();
    res.json({
      ok: true,
      bot: me,
      webhook: info,
      outbox: {
        pending: pending.size,
        failed: failed.docs.map((d) => ({
          chatId: d.data().chatId,
          attempts: d.data().attempts,
          error: String(d.data().error ?? "").slice(0, 160),
        })),
      },
      updateErrors: errors.docs.map((d) => ({ id: d.id, error: String(d.data().error ?? "").slice(0, 160) })),
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e instanceof Error ? e.message : e) });
  }
});
