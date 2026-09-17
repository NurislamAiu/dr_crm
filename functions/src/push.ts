import * as admin from "firebase-admin";

/**
 * Пуш-уведомления менеджерам, которые сейчас НЕ в приложении (presence).
 * Токены — fcmTokens/{uid}.tokens (array). Мёртвые токены вычищаются.
 * Используется обоими транспортами: Wazzup (index.ts) и Telegram.
 */
export async function pushToOfflineManagers(
  rawItems: { chatId: string; title: string; body: string }[],
): Promise<void> {
  if (rawItems.length === 0) return;
  const firestore = admin.firestore();

  // Заблокированные контакты — без пушей.
  const chatIds = [...new Set(rawItems.map((i) => i.chatId))];
  const convDocs = await Promise.all(chatIds.map((id) => firestore.doc(`conversations/${id}`).get()));
  const blockedIds = new Set(convDocs.filter((d) => d.data()?.blocked === true).map((d) => d.id));
  const items = rawItems.filter((i) => !blockedIds.has(i.chatId));
  if (items.length === 0) return;

  // Кто сейчас онлайн — им пуш не нужен (они видят чат).
  const presence = await firestore.collection("presence").where("online", "==", true).get();
  const now = Date.now();
  const onlineUids = new Set(
    presence.docs
      .filter((d) => {
        const ls = (d.data().lastSeen as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        return now - ls < 120000;
      })
      .map((d) => d.id),
  );

  const tokensSnap = await firestore.collection("fcmTokens").get();
  const tokens: string[] = [];
  const ownerOf: Record<string, string> = {};
  for (const d of tokensSnap.docs) {
    if (onlineUids.has(d.id)) continue;
    if (d.data().enabled === false) continue; // менеджер отключил уведомления
    const list = (d.data().tokens ?? []) as unknown[];
    for (const t of list) {
      if (typeof t === "string" && t.length > 0) {
        tokens.push(t);
        ownerOf[t] = d.id;
      }
    }
  }
  console.log(`push: items=${items.length} onlineUids=${JSON.stringify([...onlineUids])} tokenDocs=${tokensSnap.size} tokens=${tokens.length}`);
  if (tokens.length === 0) return;

  // Личные чаты владельца (он написал первым тому, кто нам не писал) —
  // менеджерам не видны в списке, значит и пуш по ним им слать нельзя:
  // уведомление раскрыло бы и номер, и текст переписки.
  const privateOwnerOf = new Map<string, string>();
  for (const d of convDocs) {
    const owner = d.data()?.privateOwnerUid;
    if (typeof owner === "string" && owner.length > 0) privateOwnerOf.set(d.id, owner);
  }

  for (const it of items) {
    const owner = privateOwnerOf.get(it.chatId);
    const target = owner ? tokens.filter((t) => ownerOf[t] === owner) : tokens;
    if (target.length === 0) continue;
    const resp = await admin.messaging().sendEachForMulticast({
      tokens: target,
      notification: { title: it.title, body: it.body },
      data: { chatId: it.chatId, name: it.title, phone: it.chatId },
      apns: { payload: { aps: { sound: "default", badge: 1 } } },
      android: { priority: "high", notification: { sound: "default" } },
    });
    console.log(`push "${it.title}": ok=${resp.successCount} fail=${resp.failureCount} errors=${JSON.stringify(resp.responses.filter((r) => !r.success).map((r) => r.error?.code))}`);
    // Чистим невалидные токены (переустановка приложения и т.п.).
    const dead: Record<string, string[]> = {};
    resp.responses.forEach((r, i) => {
      const code = r.error?.code ?? "";
      const t = target[i];
      if (!t || r.success) return;
      if (code.includes("registration-token-not-registered") || code.includes("invalid-registration-token") || code.includes("invalid-argument")) {
        const uid = ownerOf[t];
        if (uid) (dead[uid] ??= []).push(t);
      }
    });
    for (const [uid, list] of Object.entries(dead)) {
      await firestore
        .collection("fcmTokens")
        .doc(uid)
        .set({ tokens: admin.firestore.FieldValue.arrayRemove(...list) }, { merge: true })
        .catch(() => {});
    }
  }
}
