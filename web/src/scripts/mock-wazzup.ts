import { createServer } from "node:http";
import { randomUUID } from "node:crypto";

/**
 * Mock Wazzup API для локального e2e (ТЗ §27). НЕ отправляет реальные сообщения.
 * Порт: MOCK_PORT (4000). Состояние канала: MOCK_CHANNEL_STATE (active).
 * POST /v3/message: 201; повтор crmMessageId → 400 REPEATED_CRM_MESSAGE_ID.
 */
const PORT = Number(process.env.MOCK_PORT ?? 4000);
const CHANNEL_STATE = process.env.MOCK_CHANNEL_STATE ?? "active";
const CHANNEL_ID = process.env.MOCK_CHANNEL_ID ?? "chan-1";

const seenCrmMessageIds = new Set<string>();

const server = createServer((req, res) => {
  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
  const send = (status: number, body: unknown) => {
    res.writeHead(status, { "content-type": "application/json", "x-request-id": randomUUID() });
    res.end(JSON.stringify(body));
  };

  // Тестовый медиафайл для проверки скачивания входящих (Этап 6).
  if (req.method === "GET" && url.pathname === "/media/sample.png") {
    const png = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
      "base64",
    );
    res.writeHead(200, { "content-type": "image/png", "content-length": String(png.length) });
    res.end(png);
    return;
  }

  if (req.method === "GET" && url.pathname === "/v3/channels") {
    return send(200, [
      { channelId: CHANNEL_ID, transport: "whatsapp", plainId: "77010000000", state: CHANNEL_STATE },
    ]);
  }

  if (req.method === "POST" && url.pathname === "/v3/message") {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      let body: { crmMessageId?: string; chatId?: string } = {};
      try {
        body = JSON.parse(raw || "{}");
      } catch {
        return send(400, { status: 400, error: "INVALID_MESSAGE_DATA", description: "bad json" });
      }
      if (body.crmMessageId && seenCrmMessageIds.has(body.crmMessageId)) {
        return send(400, {
          status: 400,
          requestId: randomUUID(),
          error: "REPEATED_CRM_MESSAGE_ID",
          description: "You have already sent message with same crmMessageId",
          data: { crmMessageId: body.crmMessageId },
        });
      }
      if (body.crmMessageId) seenCrmMessageIds.add(body.crmMessageId);
      return send(201, { messageId: randomUUID(), chatId: body.chatId ?? "" });
    });
    return;
  }

  send(404, { error: "NOT_FOUND" });
});

server.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(JSON.stringify({ mock: "wazzup", port: PORT, channelState: CHANNEL_STATE }));
});
