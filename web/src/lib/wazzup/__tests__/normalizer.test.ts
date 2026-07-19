import { test, expect } from "vitest";
import { normalizeWebhook, normalizeChatId } from "../normalizer";
import { verifyWebhookSecret, sha256 } from "../webhook-auth";

// 6. Webhook {test:true}
test("normalizeWebhook: распознаёт тестовый пинг", () => {
  const r = normalizeWebhook({ test: true });
  expect(r.isTest).toBe(true);
  expect(r.messages).toHaveLength(0);
});

// 7. Входящий текст
test("normalizeWebhook: входящий текст (isEcho=false → inbound)", () => {
  const r = normalizeWebhook({
    messages: [
      {
        messageId: "m1",
        channelId: "c1",
        chatType: "whatsapp",
        chatId: "7 701 123 45 67",
        dateTime: "2026-07-19T10:00:00.000Z",
        type: "text",
        text: "Привет",
        isEcho: false,
        status: "inbound",
      },
    ],
  });
  const m = r.messages[0]!;
  expect(m.direction).toBe("inbound");
  expect(m.type).toBe("text");
  expect(m.chatIdNormalized).toBe("77011234567");
  expect(m.text).toBe("Привет");
});

// 8/9. Входящее фото, голосовое, документ
test("normalizeWebhook: медиа-типы image/audio/document с контентом", () => {
  const r = normalizeWebhook({
    messages: [
      { messageId: "i", channelId: "c", chatType: "whatsapp", chatId: "77011234567", dateTime: "t", type: "image", contentUri: "https://s/a.jpg", isEcho: false },
      { messageId: "a", channelId: "c", chatType: "whatsapp", chatId: "77011234567", dateTime: "t", type: "audio", contentUri: "https://s/a.ogg", isEcho: false },
      { messageId: "d", channelId: "c", chatType: "whatsapp", chatId: "77011234567", dateTime: "t", type: "document", contentUri: "https://s/a.pdf", isEcho: false },
    ],
  });
  expect(r.messages.map((m) => m.type)).toEqual(["image", "audio", "document"]);
  expect(r.messages.every((m) => m.hasContent)).toBe(true);
});

// 11. Пропущенный звонок
test("normalizeWebhook: missing_call даёт понятную подсказку", () => {
  const r = normalizeWebhook({
    messages: [{ messageId: "mc", channelId: "c", chatType: "whatsapp", chatId: "77011234567", dateTime: "t", type: "missing_call", isEcho: false }],
  });
  expect(r.messages[0]!.displayHint).toMatch(/Пропущенный звонок/);
});

// неизвестный тип не роняет
test("normalizeWebhook: неизвестный тип → unknown + подсказка, raw сохранён", () => {
  const r = normalizeWebhook({
    messages: [{ messageId: "u", channelId: "c", chatType: "whatsapp", chatId: "77011234567", dateTime: "t", type: "sticker_v2", isEcho: false }],
  });
  const m = r.messages[0]!;
  expect(m.type).toBe("unknown");
  expect(m.rawType).toBe("sticker_v2");
  expect(m.displayHint).toMatch(/неподдерживаемого типа/);
  expect(m.raw.type).toBe("sticker_v2");
});

// 12. Отредактированное сообщение
test("normalizeWebhook: isEdited + oldInfo.oldText", () => {
  const r = normalizeWebhook({
    messages: [{ messageId: "e", channelId: "c", chatType: "whatsapp", chatId: "77011234567", dateTime: "t", type: "text", text: "новый", isEcho: false, isEdited: true, oldInfo: { oldText: "старый" } }],
  });
  expect(r.messages[0]!.isEdited).toBe(true);
  expect(r.messages[0]!.oldText).toBe("старый");
});

// 13. Удалённое сообщение
test("normalizeWebhook: isDeleted → подсказка 'Сообщение удалено'", () => {
  const r = normalizeWebhook({
    messages: [{ messageId: "del", channelId: "c", chatType: "whatsapp", chatId: "77011234567", dateTime: "t", type: "text", isEcho: false, isDeleted: true }],
  });
  expect(r.messages[0]!.isDeleted).toBe(true);
  expect(r.messages[0]!.displayHint).toBe("Сообщение удалено");
});

// 14. messages и statuses в одном webhook — обрабатываются независимо
test("normalizeWebhook: messages И statuses в одном payload", () => {
  const r = normalizeWebhook({
    messages: [{ messageId: "m", channelId: "c", chatType: "whatsapp", chatId: "77011234567", dateTime: "t", type: "text", text: "hi", isEcho: false }],
    statuses: [{ messageId: "out1", timestamp: "2026-07-19T10:00:01.000Z", status: "delivered" }],
  });
  expect(r.messages).toHaveLength(1);
  expect(r.statuses).toHaveLength(1);
  expect(r.statuses[0]!.status).toBe("delivered");
  expect(r.statuses[0]!.timestamp).toBe("2026-07-19T10:00:01.000Z");
});

// 17. Статус с ошибкой
test("normalizeWebhook: статус error с кодом", () => {
  const r = normalizeWebhook({
    statuses: [{ messageId: "x", status: "error", error: { error: "SPAM", description: "spam" } }],
  });
  expect(r.statuses[0]!.status).toBe("error");
  expect(r.statuses[0]!.errorCode).toBe("SPAM");
});

// channelsUpdates: qr / qridle
test("normalizeWebhook: channelsUpdates с qr", () => {
  const r = normalizeWebhook({
    channelsUpdates: [{ channelId: "c1", state: "qr", qr: "data:image/png;base64,AAA", timestamp: 123 }],
  });
  expect(r.channelUpdates[0]!.state).toBe("qr");
  expect(r.channelUpdates[0]!.qr).toContain("base64");
});

test("normalizeChatId: whatsapp оставляет только цифры", () => {
  expect(normalizeChatId("whatsapp", "+7 (701) 123-45-67")).toBe("77011234567");
  expect(normalizeChatId("telegram", "  user123 ")).toBe("user123");
});

// webhook secret
test("verifyWebhookSecret: принимает Bearer и ?secret", () => {
  expect(
    verifyWebhookSecret({ expectedSecret: "s3cret", authorizationHeader: "Bearer s3cret", urlSecret: null }),
  ).toBe(true);
  expect(
    verifyWebhookSecret({ expectedSecret: "s3cret", authorizationHeader: null, urlSecret: "s3cret" }),
  ).toBe(true);
  expect(
    verifyWebhookSecret({ expectedSecret: "s3cret", authorizationHeader: "Bearer wrong", urlSecret: "wrong" }),
  ).toBe(false);
  expect(
    verifyWebhookSecret({ expectedSecret: "", authorizationHeader: "Bearer ", urlSecret: null }),
  ).toBe(false);
});

// 15. Повторный webhook → одинаковый sha256
test("sha256: стабилен для одинакового тела", () => {
  const body = JSON.stringify({ messages: [{ messageId: "m" }] });
  expect(sha256(body)).toBe(sha256(body));
  expect(sha256(body)).not.toBe(sha256(body + " "));
});
