# crm-web — backend + тонкая админка (Wazzup User API v3, WhatsApp QR)

Сервер собственной CRM: приём/отправка WhatsApp через Wazzup (транспорт
`whatsapp`, QR), REST + WebSocket для **мобильного приложения менеджеров на
Flutter**, и тонкая веб-админка (настройка webhook, диагностика).
Архитектура и сверка с документацией — в [`../architecture.md`](../architecture.md).

> Клиент менеджеров — **Flutter-приложение** (репозиторий в корне). Этот пакет —
> backend для него + админка. Веб-UI чатов не строится.

## Статус

| Этап | Содержание | Статус |
|---|---|---|
| 1 | WazzupApiClient, env, GET channels, диагностика | ✅ |
| 2 | webhook endpoint, raw storage, очередь, нормализатор, дедуп | ✅ (e2e на Docker) |
| 3 | Contact/Conversation/Message, входящие, realtime (Socket.IO) | ✅ (e2e на Docker) |
| 5 | отправка (POST /v3/message), crmMessageId, статусы, retry | ✅ (e2e с mock) |
| 4 | Flutter-приложение (чаты/composer/статусы) | ✅ (analyze+тесты) |
| 6 | медиа (S3/MinIO): входящие download, отправка вложений, signed URL | ✅ (e2e) |
| 7 | JWT-логин, RBAC, захват/передача/закрытие, заметки, «печатает» | ✅ (e2e) |
| 8 | sync users/contacts, диагностика §25, тесты, hardening | ⏳ |

Авторизация: `POST /api/auth/login` → JWT (Bearer). DEV-логин: `manager@example.com` / `password`.

API для приложения:
- `GET /api/conversations`, `GET /api/conversations/:id/messages`
- `POST /api/conversations/:id/messages/send` (тело: `text`, `replyToMessageId?`)
- `POST /api/conversations/:id/messages/send-media` (multipart: `file`, `caption?`)
- `POST /api/messages/:id/retry`
- `GET /api/attachments/:id/url` (короткий signed URL вложения)
- `POST /api/auth/login` (email/password → JWT)
- `POST /api/conversations/:id/action` (claim|transfer|close|reopen)
- `GET|POST /api/conversations/:id/notes` (внутренние заметки)
Realtime: Socket.IO на :3001 (`npm run realtime`), события §23 через Redis pub/sub.
Локальный mock Wazzup для e2e отправки: `node --import tsx src/scripts/mock-wazzup.ts` (:4000),
затем запустить worker с `WAZZUP_API_BASE_URL=http://localhost:4000`.

## Структура (Этапы 1–2)

```
web/
├── docker-compose.yml          # Postgres + Redis + MinIO (dev-инфра)
├── prisma/schema.prisma        # WazzupWebhookEvent, InboundMessageReceipt
├── src/
│   ├── app/
│   │   ├── api/webhooks/wazzup/route.ts   # приём webhook: raw+sha256, дедуп, enqueue, 200
│   │   └── api/health/route.ts            # health (Postgres+Redis)
│   ├── lib/
│   │   ├── env.ts, logger.ts              # env-валидация, маскирование
│   │   ├── db.ts, redis.ts                # Prisma / ioredis синглтоны
│   │   ├── queue/webhook-queue.ts         # BullMQ очередь (jobId=eventId)
│   │   └── wazzup/                         # client, schemas, errors, normalizer, webhook-auth, ...
│   └── worker/                             # BullMQ worker: нормализация + дедуп + обработка
```

## Запуск (dev)

```bash
cp .env.example .env            # заполнить при необходимости (дефолты подходят для локали)
docker compose up -d            # Postgres, Redis, MinIO
npm install
npm run db:migrate              # применить миграции Prisma
npm run db:seed                 # организация default + менеджеры
npm run dev                     # Next.js (API + админка) на :3000
npm run worker                  # отдельный терминал — BullMQ worker
npm run realtime                # отдельный терминал — Socket.IO на :3001
```

Проверки:
```bash
npm run typecheck               # tsc --noEmit (strict) — 0 ошибок
npm test                        # vitest — 33 теста
curl http://localhost:3000/api/health
```

### Пример проверки webhook

```bash
SEC=dev-webhook-secret
# тест-пинг
curl -X POST "http://localhost:3000/api/webhooks/wazzup?secret=$SEC" -d '{"test":true}'
# входящее сообщение (Bearer-вариант секрета)
curl -X POST http://localhost:3000/api/webhooks/wazzup \
  -H "authorization: Bearer $SEC" -H 'content-type: application/json' \
  -d '{"messages":[{"messageId":"m1","channelId":"c1","chatType":"whatsapp","chatId":"77011234567","dateTime":"2026-07-19T10:00:00Z","type":"text","text":"hi","isEcho":false}]}'
```

## Дальше (Этап 3)

Полные Prisma-модели (Contact/Conversation/Message/RBAC/…), создание клиента и
диалога из входящих (без дублей), unreadCount, WebSocket-события — сервер для
Flutter-приложения.
