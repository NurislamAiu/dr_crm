# crm-web — интерфейс чатов CRM поверх Wazzup User API v3 (WhatsApp QR)

Backend + frontend собственной CRM для приёма/отправки WhatsApp-сообщений через
Wazzup (транспорт `whatsapp`, QR-подключение). Wazzup используется только как
транспорт. Архитектура и сверка с официальной документацией — в
[`../architecture.md`](../architecture.md).

> ⚠️ Расхождения ТЗ с официальной документацией Wazzup зафиксированы в
> `architecture.md §1` (главное: состояние QR называется `qr`, а не `qridle`;
> окно дедупа `crmMessageId` — 60 сек; в статусах поле `timestamp`).

## Статус

| Этап | Содержание | Статус |
|---|---|---|
| 1 | architecture.md, WazzupApiClient, env-валидация, GET channels, диагностика | ✅ готово |
| 2 | webhook endpoint, очередь, нормализатор, дедуп | ⏳ |
| 3–8 | входящие/realtime, UI, отправка, медиа, RBAC, sync/мониторинг/тесты | ⏳ |

## Что уже есть (Этап 1)

```
web/src/lib/
├── env.ts                      # Zod-валидация окружения, запрет NEXT_PUBLIC ключа
├── logger.ts                   # структурный лог + маскирование ключа/телефонов
└── wazzup/
    ├── client.ts               # WazzupApiClient — единая точка вызовов Wazzup
    ├── schemas.ts              # Zod-схемы v3 (выверены по документации)
    ├── errors.ts               # WazzupApiError / WazzupTimeoutError + safe-текст
    ├── channel-state.ts        # state канала → поведение UI (canSend, сообщения)
    ├── diagnostics.ts          # сбор диагностики (ключ/канал/webhook)
    ├── factory.ts              # getWazzupClient() из env (singleton)
    └── __tests__/              # mock Wazzup server + юнит-тесты (реальные сообщения не шлются)
```

`WazzupApiClient` реализует методы §4 ТЗ: `getChannels, sendTextMessage,
sendMediaMessage, replyToMessage, editMessage, deleteMessage, configureWebhooks,
getWebhookSettings, syncUsers, syncContacts, testConnection` (+ `getUsers`).
Каждый запрос: `Authorization: Bearer`, timeout, `Content-Type: application/json`,
Zod-валидация ответа, маскирование ключа, `requestId` при ошибках, обработка
400/401/403/429/500, retry только для безопасных методов, без авто-ретрая отправки.

## Команды

```bash
npm install
npm run typecheck   # tsc --noEmit (strict)
npm test            # tsc + node --test dist  (20 тестов)
npm run build       # компиляция в dist/
```

## Окружение

Скопировать `.env.example` → `.env` и заполнить. `WAZZUP_API_KEY` — секрет,
только backend. **Запрещено** создавать `NEXT_PUBLIC_WAZZUP_API_KEY` (env.ts
падает при обнаружении).

## Дальше (Этап 2)

Добавляется Next.js App Router (route handlers), Prisma, Redis/BullMQ, Socket.IO.
На этом этапе появятся HTTP-маршруты, оборачивающие сервисы Этапа 1:
`GET /api/admin/wazzup/diagnostics`, `POST /api/webhooks/wazzup`, кнопки
«Настроить webhook» / «Проверить webhook».
