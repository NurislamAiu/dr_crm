import { test, expect } from "vitest";
import { _chunkForTest } from "../sync";
import { WazzupApiClient } from "@/lib/wazzup/client";
import { MockWazzupServer } from "@/lib/wazzup/__tests__/mock-server";

test("chunk: разбивает по 100 (§26)", () => {
  const arr = Array.from({ length: 250 }, (_, i) => i);
  const batches = _chunkForTest(arr, 100);
  expect(batches).toHaveLength(3);
  expect(batches[0]).toHaveLength(100);
  expect(batches[2]).toHaveLength(50);
});

test("client.syncUsers: батч ≤100 уходит одним POST /v3/users", async () => {
  const server = new MockWazzupServer().on("POST /v3/users", { status: 200, body: {} });
  const client = new WazzupApiClient({ baseUrl: "https://api.wazzup24.com", apiKey: "k", fetchImpl: server.fetch });
  await client.syncUsers(Array.from({ length: 100 }, (_, i) => ({ id: `u${i}`, name: `U${i}` })));
  expect(server.requests).toHaveLength(1);
  expect(server.requests[0]?.path).toBe("/v3/users");
});

test("client.syncContacts: >100 контактов → ошибка лимита", async () => {
  const server = new MockWazzupServer();
  const client = new WazzupApiClient({ baseUrl: "https://api.wazzup24.com", apiKey: "k", fetchImpl: server.fetch });
  const contacts = Array.from({ length: 101 }, (_, i) => ({
    id: `c${i}`,
    responsibleUserId: "u1",
    name: `C${i}`,
    contactData: [{ chatType: "whatsapp" as const, chatId: "77010000000" }],
  }));
  await expect(client.syncContacts(contacts)).rejects.toThrow(/не более 100/);
});
