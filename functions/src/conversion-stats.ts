/**
 * Разовый анализ конверсии «написал нам → стал лидом» + где теряем клиентов:
 * скорость ответа и время суток обращения.
 *
 * Не отдельная фича с своим UI — диагностика по требованию через
 * ?action=convstats в tgSetup. Три уровня определения аудитории:
 *
 *  • активныйЧат — написал нам хотя бы раз за период (conv.lastInboundAt).
 *    Тут и старые клиенты, написавшие снова, — конверсия занижена относительно
 *    «продажи новым».
 *  • новыйКонтакт — документ чата в Firestore СОЗДАН в этот период
 *    (doc.createTime, метаданные — не поле, которое можно случайно стереть
 *    мержем). Это и есть реально новый человек, а не давний клиент.
 *  • лид — запись в коллекции leads (не архивная), сопоставлена по номеру
 *    телефона. Это фактическая продажа: имя, дата приёма, предоплата.
 *
 * Скорость ответа считаем ТОЧЕЧНЫМИ запросами по каждому новому чату (не
 * сканированием всей коллекции messages за месяц — это десятки тысяч
 * документов и не поместится в разумный таймаут). Хватает первых ~15
 * сообщений чата, чтобы найти первое входящее и первый ответ.
 */
import * as admin from "firebase-admin";
import { isOwnTabTopic } from "./topics";

const db = () => admin.firestore();

function normPhone(v: unknown): string {
  return String(v ?? "").replace(/\D/g, "");
}

function median(xs: number[]): number | null {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)] ?? null;
}

type ActiveChat = { id: string; data: FirebaseFirestore.DocumentData; createdMs: number };

/**
 * Чаты, написавшие нам за период — с пагинацией курсором: у активной клиники
 * их за месяц легко больше 3000, а один limit() без orderBy молча вернул бы
 * ПРОИЗВОЛЬНЫЕ 3000 (на практике — самые старые из периода по lastInboundAt),
 * искажая всю картину «новые/повторные».
 */
async function chatsSincePeriodStart(firestore: FirebaseFirestore.Firestore, startMs: number): Promise<{ active: ActiveChat[]; newChats: ActiveChat[] }> {
  const startTs = admin.firestore.Timestamp.fromMillis(startMs);
  const convDocs: FirebaseFirestore.QueryDocumentSnapshot[] = [];
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
  for (let page = 0; page < 20; page++) {
    let q = firestore.collection("conversations").where("lastInboundAt", ">=", startTs).orderBy("lastInboundAt", "asc").limit(1000);
    if (cursor) q = q.startAfter(cursor);
    const snap = await q.get();
    if (snap.empty) break;
    convDocs.push(...snap.docs);
    cursor = snap.docs[snap.docs.length - 1] ?? null;
    if (snap.size < 1000) break;
  }
  const active = convDocs
    .map((d) => ({ id: d.id, data: d.data(), createdMs: d.createTime.toMillis() }))
    .filter((c) => c.data.blocked !== true && !isOwnTabTopic(c.data.topic));
  const newChats = active.filter((c) => c.createdMs >= startMs);
  return { active, newChats };
}

/** Телефон → самая ранняя дата лида (не архивного) с этим телефоном, по всей истории. */
export async function leadPhoneIndex(firestore: FirebaseFirestore.Firestore): Promise<Map<string, number>> {
  // Лиды за всё время (не только за период): бронь могла случиться позже
  // первого сообщения, и старый лид всё равно значит «этот человек купил».
  const leadsSnap = await firestore.collection("leads").limit(5000).get();
  const leadPhones = new Map<string, number>();
  for (const d of leadsSnap.docs) {
    const x = d.data();
    if (x.archived === true) continue;
    const p = normPhone(x.phone);
    if (!p) continue;
    const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
    const cur = leadPhones.get(p);
    if (cur === undefined || at < cur) leadPhones.set(p, at);
  }
  return leadPhones;
}

/** Отображаемые имена менеджеров: users/{uid}.name, иначе первые буквы uid. */
async function managerNames(firestore: FirebaseFirestore.Firestore): Promise<Map<string, string>> {
  const usersSnap = await firestore.collection("users").limit(50).get();
  return new Map(usersSnap.docs.map((d) => [d.id, String(d.data().name ?? "").trim() || d.id.slice(0, 6)]));
}

export async function computeConversionStats(days: number) {
  const firestore = db();
  const startMs = Date.now() - days * 86_400_000;

  const { active, newChats } = await chatsSincePeriodStart(firestore, startMs);
  const repeatChats = active.length - newChats.length;

  const leadPhones = await leadPhoneIndex(firestore);
  const isConverted = (c: { data: FirebaseFirestore.DocumentData }): boolean => leadPhones.has(normPhone(c.data.phone));

  const newConverted = newChats.filter(isConverted).length;
  const activeConverted = active.filter(isConverted).length;

  // ── Скорость ответа + полное молчание — по НОВЫМ чатам, точечными запросами. ──
  type Sample = { converted: boolean; firstInboundAt: number; firstReplyAt: number | null; firstHumanReplyAt: number | null; hour: number };
  const samples: Sample[] = [];
  // Равномерная выборка по всему периоду, а не первые N подряд: newChats
  // отсортирован по времени (из пагинации), и «первые 400» были бы только
  // началом периода — необъективно для разбивки по часам и дням.
  const SAMPLE_CAP = 700;
  const step = Math.max(1, Math.floor(newChats.length / SAMPLE_CAP));
  const capped = newChats.filter((_, i) => i % step === 0).slice(0, SAMPLE_CAP);
  for (const c of capped) {
    const msnap = await firestore
      .collection("messages")
      .where("conversationId", "==", c.id)
      .orderBy("createdAt", "asc")
      .limit(15)
      .get();
    let firstInboundAt: number | null = null;
    let firstReplyAt: number | null = null;
    let firstHumanReplyAt: number | null = null;
    for (const md of msnap.docs) {
      const x = md.data();
      if (x.isInternal === true || x.type === "call" || x.isDeleted === true) continue;
      const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      if (x.direction === "inbound") {
        firstInboundAt ??= at;
      } else if (x.direction === "outbound" && firstInboundAt !== null && at >= firstInboundAt) {
        firstReplyAt ??= at;
        // authorId "auto" — бот (автоответ/ИИ/очередь). Его createdAt пишется
        // в момент ПОСТАНОВКИ В ОЧЕРЕДЬ, а не реальной отправки, — по нему
        // нельзя мерить, насколько быстро отреагировал человек. Живой
        // менеджер отвечает синхронно (без очереди), createdAt = момент
        // отправки, поэтому только authorId≠auto годится для оценки скорости.
        if (String(x.authorId ?? "") !== "auto") firstHumanReplyAt ??= at;
      }
    }
    if (firstInboundAt === null) continue;
    const hourAstana = new Date(firstInboundAt + 5 * 3600_000).getUTCHours();
    samples.push({ converted: isConverted(c), firstInboundAt, firstReplyAt, firstHumanReplyAt, hour: hourAstana });
  }

  const silent = samples.filter((s) => s.firstReplyAt === null).length; // не ответил вообще НИКТО, даже бот
  const botOnlyNoHuman = samples.filter((s) => s.firstReplyAt !== null && s.firstHumanReplyAt === null).length; // бот ответил, человек — нет

  // Скорость — только по ЖИВОМУ ответу менеджера. Медиана по firstReplyAt
  // (включая ботов) была бы бессмысленной: автоответ ставится в очередь
  // почти мгновенно после входящего (createdAt = момент постановки, не
  // доставки), и такая «скорость» показывала бы 2–9 секунд для ВСЕХ чатов —
  // это скорость очереди, а не человека.
  const withHuman = samples.filter((s) => s.firstHumanReplyAt !== null);
  const delays = withHuman.map((s) => ({ ...s, delayMs: (s.firstHumanReplyAt as number) - s.firstInboundAt }));

  function p(xs: number[], q: number): number | null {
    if (xs.length === 0) return null;
    const s = [...xs].sort((a, b) => a - b);
    return s[Math.min(s.length - 1, Math.floor(s.length * q))] ?? null;
  }
  const shareOver = (xs: number[], ms: number) => (xs.length > 0 ? `${((xs.filter((x) => x > ms).length / xs.length) * 100).toFixed(0)}%` : "нет данных");

  const dConv = delays.filter((d) => d.converted).map((d) => d.delayMs);
  const dNot = delays.filter((d) => !d.converted).map((d) => d.delayMs);
  const medConverted = median(dConv);
  const medNotConverted = median(dNot);
  const p75Converted = p(dConv, 0.75);
  const p75NotConverted = p(dNot, 0.75);

  const byHour = new Map<number, { total: number; converted: number; noReply: number; noHuman: number }>();
  for (const s of samples) {
    const b = byHour.get(s.hour) ?? { total: 0, converted: 0, noReply: 0, noHuman: 0 };
    b.total++;
    if (s.converted) b.converted++;
    if (s.firstReplyAt === null) b.noReply++;
    if (s.firstHumanReplyAt === null) b.noHuman++;
    byHour.set(s.hour, b);
  }
  const fmtMin = (ms: number | null) => (ms === null ? "нет данных" : ms < 60_000 ? `${Math.round(ms / 1000)} сек` : `${Math.round(ms / 60_000)} мин`);
  const pct = (n: number, of: number) => (of > 0 ? `${((n / of) * 100).toFixed(1)}%` : "нет данных");

  // ── Тренд по дням — на ВСЕХ новых чатах (5к+), без доп. запросов: день и
  // конверсия уже известны из newChats/isConverted, точечные запросы к
  // messages тут не нужны. Даёт куда более точную картину, чем 700-выборка. ──
  const byDay = new Map<string, { total: number; converted: number }>();
  for (const c of newChats) {
    const day = new Date(c.createdMs + 5 * 3600_000).toISOString().slice(0, 10); // Астана UTC+5
    const b = byDay.get(day) ?? { total: 0, converted: 0 };
    b.total++;
    if (isConverted(c)) b.converted++;
    byDay.set(day, b);
  }

  // ── Гистограмма скорости живого ответа — по тем же delays, что медианы выше. ──
  const SPEED_BUCKETS: { label: string; maxMs: number }[] = [
    { label: "<5 мин", maxMs: 5 * 60_000 },
    { label: "5–15 мин", maxMs: 15 * 60_000 },
    { label: "15–30 мин", maxMs: 30 * 60_000 },
    { label: "30–60 мин", maxMs: 60 * 60_000 },
    { label: "1–2 ч", maxMs: 2 * 3600_000 },
    { label: ">2 ч", maxMs: Infinity },
  ];
  const bucketOf = (ms: number) => SPEED_BUCKETS.find((b) => ms <= b.maxMs)?.label ?? SPEED_BUCKETS[SPEED_BUCKETS.length - 1]!.label;
  const histConv = new Map<string, number>();
  const histNot = new Map<string, number>();
  for (const b of SPEED_BUCKETS) {
    histConv.set(b.label, 0);
    histNot.set(b.label, 0);
  }
  for (const ms of dConv) histConv.set(bucketOf(ms), (histConv.get(bucketOf(ms)) ?? 0) + 1);
  for (const ms of dNot) histNot.set(bucketOf(ms), (histNot.get(bucketOf(ms)) ?? 0) + 1);

  return {
    период: `${days} дней`,
    методика: {
      активныйЧат: "написал нам хотя бы раз за период (conv.lastInboundAt)",
      новыйКонтакт: "чат впервые появился в CRM за этот период (не давний клиент)",
      лид: "запись в коллекции leads (не в архиве), сопоставлена по номеру телефона — это факт продажи",
    },
    активныеЧаты: active.length,
    изНихПовторныеСтарые: repeatChats,
    изНихНовые: newChats.length,
    новыхСталоЛидом: newConverted,
    конверсияНовыхВЛида: pct(newConverted, newChats.length),
    конверсияВсехАктивныхВЛида: pct(activeConverted, active.length),
    выборкаСкоростиОтвета: samples.length,
    полностьюБезОтвета: silent,
    полностьюБезОтветаДоля: pct(silent, samples.length),
    ответилТолькоБотЧеловекНеПодключился: botOnlyNoHuman,
    ответилТолькоБотДоля: pct(botOnlyNoHuman, samples.length),
    "─скоростьНиже─": "только реальный ответ менеджера, без автоответов/ИИ/очереди — их createdAt отражает момент постановки в очередь, а не отправки",
    медианаОтветаУКонвертированных: fmtMin(medConverted),
    медианаОтветаУНеКонвертированных: fmtMin(medNotConverted),
    "75йПерцентильУКонвертированных(4изКаждых5отвеченыБыстрее)": fmtMin(p75Converted),
    "75йПерцентильУНеКонвертированных": fmtMin(p75NotConverted),
    ждалиОтветаБолее30МинУКонвертированных: shareOver(dConv, 30 * 60_000),
    ждалиОтветаБолее30МинУНеКонвертированных: shareOver(dNot, 30 * 60_000),
    ждалиОтветаБолее2ЧасовУКонвертированных: shareOver(dConv, 2 * 3600_000),
    ждалиОтветаБолее2ЧасовУНеКонвертированных: shareOver(dNot, 2 * 3600_000),
    поЧасамАстана: [...byHour.entries()]
      .sort((a, b) => a[0] - b[0])
      .map(([h, b]) => ({
        час: h,
        обращений: b.total,
        безОтветаВообще: b.noReply,
        безЖивогоОтвета: b.noHuman,
        сталоЛидом: b.converted,
        конверсия: pct(b.converted, b.total),
      })),
    поДням: [...byDay.entries()]
      .sort((a, b) => (a[0] < b[0] ? -1 : 1))
      .map(([day, b]) => ({ день: day, новыхКонтактов: b.total, сталоЛидом: b.converted, конверсия: pct(b.converted, b.total) })),
    гистограммаСкоростиОтвета: SPEED_BUCKETS.map((b) => ({
      диапазон: b.label,
      конвертированные: histConv.get(b.label) ?? 0,
      неКонвертированные: histNot.get(b.label) ?? 0,
    })),
  };
}

/**
 * Та же конверсия, но по менеджерам: кто первым отвечает живым сообщением
 * новым чатам, с какой скоростью и с какой конверсией в лида — плюс сколько
 * лидов менеджер реально оформил (leads.createdBy) за тот же период.
 *
 * «Взял чат» = его authorId стоит на ПЕРВОМ живом (не auto) исходящем в этом
 * чате. Кто закрыл сделку дальше — не всегда тот же человек (могли передать),
 * но кто первым вступил в разговор — самый честный сигнал «кто вообще
 * работал с этим клиентом», доступный без ручной разметки ответственных.
 */
export async function computeManagerStats(days: number) {
  const firestore = db();
  const startMs = Date.now() - days * 86_400_000;
  const startTs = admin.firestore.Timestamp.fromMillis(startMs);

  const names = await managerNames(firestore);
  const nameOf = (uid: string) => names.get(uid) ?? uid.slice(0, 8);

  // Лиды, реально оформленные каждым менеджером в этот период — прямая
  // цифра из карточки лида, без сопоставления по телефону. Группируем по
  // ИМЕНИ, а не uid: после восстановления аккаунта в Firebase у менеджера
  // меняется uid, и группировка по uid развалила бы одного человека на две
  // строки с одинаковым именем и разными (заниженными) цифрами.
  const leadsPeriodSnap = await firestore.collection("leads").where("createdAt", ">=", startTs).get();
  const leadsCreatedByMgr = new Map<string, number>();
  let leadsNoOwner = 0;
  for (const d of leadsPeriodSnap.docs) {
    const x = d.data();
    if (x.archived === true) continue;
    const uid = String(x.createdBy ?? "");
    if (!uid) {
      leadsNoOwner++;
      continue;
    }
    const name = nameOf(uid);
    leadsCreatedByMgr.set(name, (leadsCreatedByMgr.get(name) ?? 0) + 1);
  }

  const { newChats } = await chatsSincePeriodStart(firestore, startMs);
  const leadPhones = await leadPhoneIndex(firestore);

  const SAMPLE_CAP = 700;
  const step = Math.max(1, Math.floor(newChats.length / SAMPLE_CAP));
  const capped = newChats.filter((_, i) => i % step === 0).slice(0, SAMPLE_CAP);

  type Row = { mgr: string; converted: boolean; delayMs: number | null };
  const rows: Row[] = [];
  let unassigned = 0; // чат без единого живого ответа — некому приписать
  for (const c of capped) {
    const msnap = await firestore.collection("messages").where("conversationId", "==", c.id).orderBy("createdAt", "asc").limit(15).get();
    let firstInboundAt: number | null = null;
    let firstHumanReplyAt: number | null = null;
    let firstHumanAuthor: string | null = null;
    for (const md of msnap.docs) {
      const x = md.data();
      if (x.isInternal === true || x.type === "call" || x.isDeleted === true) continue;
      const at = (x.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
      if (x.direction === "inbound") {
        firstInboundAt ??= at;
      } else if (x.direction === "outbound" && firstInboundAt !== null && at >= firstInboundAt) {
        const author = String(x.authorId ?? "");
        if (author && author !== "auto" && firstHumanAuthor === null) {
          firstHumanAuthor = author;
          firstHumanReplyAt = at;
        }
      }
    }
    if (firstInboundAt === null) continue;
    if (!firstHumanAuthor) {
      unassigned++;
      continue;
    }
    rows.push({
      mgr: nameOf(firstHumanAuthor), // по имени — та же причина, см. выше про leadsCreatedByMgr
      converted: leadPhones.has(normPhone(c.data.phone)),
      delayMs: firstHumanReplyAt !== null ? firstHumanReplyAt - firstInboundAt : null,
    });
  }

  const byMgr = new Map<string, { total: number; converted: number; delays: number[] }>();
  for (const r of rows) {
    const b = byMgr.get(r.mgr) ?? { total: 0, converted: 0, delays: [] };
    b.total++;
    if (r.converted) b.converted++;
    if (r.delayMs !== null) b.delays.push(r.delayMs);
    byMgr.set(r.mgr, b);
  }

  const fmtMin = (ms: number | null) => (ms === null ? "нет данных" : ms < 60_000 ? `${Math.round(ms / 1000)} сек` : `${Math.round(ms / 60_000)} мин`);
  const pct = (n: number, of: number) => (of > 0 ? `${((n / of) * 100).toFixed(1)}%` : "нет данных");

  const managers = [...byMgr.entries()]
    .map(([name, b]) => ({
      менеджер: name,
      новыхЧатовВзял: b.total,
      сталоЛидом: b.converted,
      конверсия: pct(b.converted, b.total),
      медианаОтветаМенеджера: fmtMin(median(b.delays)),
      лидовОформилСам: leadsCreatedByMgr.get(name) ?? 0,
    }))
    .sort((a, b) => b.новыхЧатовВзял - a.новыхЧатовВзял);

  return {
    период: `${days} дней`,
    методика: {
      взялЧат: "первым ответил живым сообщением (не автоответ/ИИ/очередь) — не всегда тот же человек, кто довёл до записи",
      конверсия: "доля таких чатов, где телефон совпал с записью в leads",
      лидовОформилСам: "прямая цифра — сколько записей (leads) этот менеджер лично создал за период, без сопоставления по телефону",
    },
    выборкаЧатов: capped.length,
    безЖивогоОтветаВообще: unassigned,
    лидовБезАвтора: leadsNoOwner,
    менеджеры: managers,
  };
}
