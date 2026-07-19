import { io } from "socket.io-client";

/** Тестовый слушатель realtime: подключается, логирует события N секунд. */
const socket = io(process.env.REALTIME_URL ?? "http://localhost:3001", {
  auth: { organizationId: "default", userId: process.env.LISTEN_USER ?? "" },
  transports: ["websocket"],
});

const events = ["conversation.created", "conversation.updated", "conversation.assigned", "message.created", "message.updated", "message.status.updated", "channel.state.updated", "notification.created"];

socket.on("connect", () => console.log(JSON.stringify({ rt: "connected", id: socket.id })));
socket.on("connect_error", (e) => console.log(JSON.stringify({ rt: "connect_error", error: e.message })));
for (const ev of events) {
  socket.on(ev, (data) => console.log(JSON.stringify({ rt: ev, payload: data.payload })));
}

setTimeout(() => {
  socket.close();
  process.exit(0);
}, Number(process.env.LISTEN_MS ?? 8000));
