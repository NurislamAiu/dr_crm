import { test } from "vitest";
import assert from "node:assert/strict";
import { WazzupApiClient } from "../client";
import { WazzupApiError, WazzupTimeoutError } from "../errors";
import { evaluateChannelState, findWhatsappChannel } from "../channel-state";
import type { Channel } from "../schemas";
import { MockWazzupServer } from "./mock-server";

function makeClient(server: MockWazzupServer, overrides = {}): WazzupApiClient {
  return new WazzupApiClient({
    baseUrl: "https://api.wazzup24.com",
    apiKey: "test-key-1234",
    fetchImpl: server.fetch,
    maxRetries: 1,
    ...overrides,
  });
}

// 1. GET /v3/channels
test("getChannels: парсит список каналов и шлёт Bearer", async () => {
  const server = new MockWazzupServer().on("GET /v3/channels", {
    status: 200,
    body: [
      { channelId: "c1", transport: "whatsapp", plainId: "77011234567", state: "active" },
      { channelId: "c2", transport: "wapi", plainId: "77000000000", state: "active" },
    ],
  });
  const channels = await makeClient(server).getChannels();
  assert.equal(channels.length, 2);
  assert.equal(server.requests[0]?.authorization, "Bearer test-key-1234");
});

// 2. Поиск transport=whatsapp (не выбирать wapi)
test("findWhatsappChannel: выбирает whatsapp, а не wapi", () => {
  const channels: Channel[] = [
    { channelId: "wapi1", transport: "wapi", plainId: "1", state: "active" },
    { channelId: "wa1", transport: "whatsapp", plainId: "77011234567", state: "active" },
  ];
  assert.equal(findWhatsappChannel(channels)?.channelId, "wa1");
});

// 3. Канал active → отправка разрешена
test("evaluateChannelState: active разрешает отправку", () => {
  const s = evaluateChannelState("active");
  assert.equal(s.canSend, true);
  assert.equal(s.adminMessage, null);
});

// 4. Канал qr (в ТЗ ошибочно qridle) → блок + сообщение про QR
test("evaluateChannelState: qr блокирует и просит пересканировать QR", () => {
  const s = evaluateChannelState("qr");
  assert.equal(s.canSend, false);
  assert.match(s.adminMessage ?? "", /QR/);
});

// 5. Канал phoneUnavailable
test("evaluateChannelState: phoneUnavailable сообщает о потере связи", () => {
  const s = evaluateChannelState("phoneUnavailable");
  assert.equal(s.canSend, false);
  assert.match(s.adminMessage ?? "", /связь с телефоном/);
});

test("evaluateChannelState: unauthorized и неизвестное состояние", () => {
  assert.match(evaluateChannelState("unauthorized").adminMessage ?? "", /не авторизован/);
  const unknown = evaluateChannelState("someNewState");
  assert.equal(unknown.canSend, false);
  assert.match(unknown.adminMessage ?? "", /Неизвестное состояние/);
});

// 22. Ошибка 401
test("getChannels: 401 → WazzupApiError с безопасным сообщением", async () => {
  const server = new MockWazzupServer().on("GET /v3/channels", {
    status: 401,
    body: { status: 401, requestId: "req-1", error: "UNAUTHORIZED", description: "bad key" },
  });
  await assert.rejects(
    () => makeClient(server).getChannels(),
    (err: unknown) => {
      assert.ok(err instanceof WazzupApiError);
      assert.equal(err.httpStatus, 401);
      assert.equal(err.requestId, "req-1");
      assert.match(err.userFacingMessage(), /авторизаци/i);
      return true;
    },
  );
});

// 23. Ошибка 429 → ретраится (safe) и в итоге успех
test("getChannels: 429 затем 200 (ретрай безопасного метода)", async () => {
  let calls = 0;
  const server = new MockWazzupServer().on("GET /v3/channels", () => {
    calls += 1;
    return calls === 1
      ? { status: 429, body: { error: "TOO_MANY_REQUESTS" } }
      : { status: 200, body: [] };
  });
  const channels = await makeClient(server, { maxRetries: 2 }).getChannels();
  assert.deepEqual(channels, []);
  assert.equal(calls, 2);
});

// 20. Повтор crmMessageId → REPEATED_CRM_MESSAGE_ID распознаётся
test("sendTextMessage: REPEATED_CRM_MESSAGE_ID помечается флагом и не ретраится", async () => {
  let calls = 0;
  const server = new MockWazzupServer().on("POST /v3/message", () => {
    calls += 1;
    return {
      status: 400,
      body: {
        status: 400,
        requestId: "r2",
        error: "REPEATED_CRM_MESSAGE_ID",
        description: "duplicate",
      },
    };
  });
  await assert.rejects(
    () =>
      makeClient(server).sendTextMessage({
        channelId: "c1",
        chatId: "77011234567",
        text: "hi",
        crmMessageId: "same-id",
      }),
    (err: unknown) => {
      assert.ok(err instanceof WazzupApiError);
      assert.equal(err.isRepeatedCrmMessageId, true);
      return true;
    },
  );
  assert.equal(calls, 1, "отправка не должна ретраиться автоматически");
});

// 17. Отправка текста → 201 messageId
test("sendTextMessage: 201 возвращает messageId и chatId", async () => {
  const server = new MockWazzupServer().on("POST /v3/message", {
    status: 201,
    body: { messageId: "m1", chatId: "77011234567" },
  });
  const res = await makeClient(server).sendTextMessage({
    channelId: "c1",
    chatId: "77011234567",
    text: "Здравствуйте!",
    crmMessageId: "uuid-1",
    clearUnanswered: true,
  });
  assert.equal(res.messageId, "m1");
  const sent = server.requests[0]?.body as Record<string, unknown>;
  assert.equal(sent.chatType, "whatsapp");
  assert.equal(sent.clearUnanswered, true);
});

// editMessage: нельзя text и contentUri одновременно
test("editMessage: запрещает text и contentUri вместе", async () => {
  const server = new MockWazzupServer();
  await assert.rejects(
    () =>
      makeClient(server).editMessage({
        messageId: "m1",
        text: "a",
        contentUri: "https://x/y",
      }),
    /ровно одно/,
  );
});

// 21. Timeout при отправке → WazzupTimeoutError, без ретрая
test("sendTextMessage: таймаут → WazzupTimeoutError и без ретрая", async () => {
  let calls = 0;
  const hangingFetch = ((_input: unknown, init?: RequestInit) => {
    calls += 1;
    // имитируем зависание; реальный fetch реджектит по abort — воспроизводим это.
    return new Promise<Response>((_resolve, reject) => {
      const signal = init?.signal;
      if (signal) {
        signal.addEventListener("abort", () => {
          const err = new Error("aborted");
          err.name = "AbortError";
          reject(err);
        });
      }
    });
  }) as typeof fetch;

  const client = new WazzupApiClient({
    baseUrl: "https://api.wazzup24.com",
    apiKey: "k",
    fetchImpl: hangingFetch,
    timeoutMs: 30,
  });
  await assert.rejects(
    () =>
      client.sendTextMessage({
        channelId: "c1",
        chatId: "77011234567",
        text: "hi",
        crmMessageId: "id",
      }),
    (err: unknown) => err instanceof WazzupTimeoutError,
  );
  assert.equal(calls, 1);
});

// syncUsers / syncContacts: лимит 100
test("syncUsers: >100 пользователей → ошибка лимита", async () => {
  const server = new MockWazzupServer();
  const users = Array.from({ length: 101 }, (_, i) => ({ id: String(i), name: `U${i}` }));
  await assert.rejects(() => makeClient(server).syncUsers(users), /не более 100/);
});
