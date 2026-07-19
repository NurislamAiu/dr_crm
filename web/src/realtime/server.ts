import { createServer } from "node:http";
import { Server as SocketIOServer } from "socket.io";
import IORedis from "ioredis";
import { logger } from "@/lib/logger";
import { REALTIME_CHANNEL, type RealtimeEvent } from "@/lib/realtime/events";
import { verifyJwt } from "@/lib/auth/jwt";

// Загружаем .env: realtime-сервер не импортирует Prisma (который делает это сам),
// поэтому AUTH_SECRET/REDIS_URL нужно подтянуть явно. В проде env — из окружения.
try {
  process.loadEnvFile();
} catch {
  /* .env отсутствует — берём переменные из окружения */
}

/**
 * Отдельный Socket.IO-сервер (ТЗ §23). Подписан на Redis pub/sub и раздаёт
 * события подключённым клиентам (Flutter-приложение, админка) в комнаты
 * своей организации/диалога. Так каждый получает только события своей орг.
 *
 * Аутентификация: JWT в handshake (auth.token), org/user берём из подписанного токена.
 */

const PORT = Number(process.env.REALTIME_PORT ?? 3001);
const REDIS_URL = process.env.REDIS_URL ?? "redis://localhost:6379";

const httpServer = createServer((_req, res) => {
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ status: "ok", service: "realtime" }));
});

const io = new SocketIOServer(httpServer, {
  cors: { origin: process.env.APP_URL ?? "*" },
});

interface Handshake {
  token?: string;
}

const AUTH_SECRET = process.env.AUTH_SECRET ?? "";

io.use((socket, next) => {
  const auth = (socket.handshake.auth ?? {}) as Handshake;
  const token = auth.token ?? (socket.handshake.query.token as string | undefined);
  if (!token || !AUTH_SECRET) return next(new Error("auth token required"));
  const payload = verifyJwt(token, AUTH_SECRET);
  if (!payload) return next(new Error("invalid token"));
  // org/user берём ТОЛЬКО из подписанного токена (§24), не из произвольных полей.
  socket.data.organizationId = payload.org;
  socket.data.userId = payload.sub;
  socket.data.userName = payload.name ?? "";
  next();
});

io.on("connection", (socket) => {
  const orgId = socket.data.organizationId as string;
  const userId = socket.data.userId as string | undefined;
  socket.join(`org:${orgId}`);
  if (userId) socket.join(`user:${userId}`);
  logger.info("realtime: клиент подключён", { orgId, userId, socketId: socket.id });

  // Клиент присоединяется к комнате конкретного диалога (только своей орг).
  socket.on("conversation:subscribe", (conversationId: string) => {
    socket.join(`conv:${orgId}:${conversationId}`);
  });
  socket.on("conversation:unsubscribe", (conversationId: string) => {
    socket.leave(`conv:${orgId}:${conversationId}`);
  });

  // «Печатает» (§19): широковещаем в комнату диалога, кроме отправителя.
  socket.on("typing", (data: { conversationId?: string; typing?: boolean }) => {
    if (!data?.conversationId) return;
    socket.to(`conv:${orgId}:${data.conversationId}`).emit("user.typing", {
      event: "user.typing",
      organizationId: orgId,
      conversationId: data.conversationId,
      payload: { userId, userName: socket.data.userName, typing: data.typing !== false },
      ts: new Date().toISOString(),
    });
  });

  socket.on("disconnect", () => {
    logger.info("realtime: клиент отключён", { socketId: socket.id });
  });
});

// --- Подписка на Redis pub/sub и ретрансляция ---
const sub = new IORedis(REDIS_URL, { maxRetriesPerRequest: null });
sub.subscribe(REALTIME_CHANNEL, (err) => {
  if (err) logger.error("realtime: не удалось подписаться на Redis", { error: err.message });
  else logger.info("realtime: подписан на Redis-канал", { channel: REALTIME_CHANNEL });
});

sub.on("message", (_channel, raw) => {
  let evt: RealtimeEvent;
  try {
    evt = JSON.parse(raw) as RealtimeEvent;
  } catch {
    return;
  }
  const orgRoom = `org:${evt.organizationId}`;
  // notification.* адресуем конкретному пользователю, если указан.
  if (evt.userId && evt.event === "notification.created") {
    io.to(`user:${evt.userId}`).emit(evt.event, evt);
    return;
  }
  if (evt.conversationId) {
    io.to(`conv:${evt.organizationId}:${evt.conversationId}`).to(orgRoom).emit(evt.event, evt);
  } else {
    io.to(orgRoom).emit(evt.event, evt);
  }
});

httpServer.listen(PORT, () => {
  logger.info("realtime: сервер запущен", { port: PORT });
});

async function shutdown(signal: string): Promise<void> {
  logger.info("realtime: остановка", { signal });
  await sub.quit().catch(() => {});
  io.close();
  httpServer.close();
  process.exit(0);
}
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));
