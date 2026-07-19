# Architecture — CRM ↔ Wazzup User API v3 (WhatsApp QR)

> Версия документа: Этап 1. Документ живой — обновляется на каждом этапе.
> Транспорт: **`whatsapp`** (QR-подключение). Это **не** WABA. WABA-шаблоны,
> 24-часовые окна Meta и `transport="wapi"` в основной логике не используются.

---

## 0. Результат аудита существующего проекта

| Что предполагает ТЗ | Что реально в репозитории |
|---|---|
| Существующая CRM (Next.js/NestJS, TS, Prisma, Postgres, Redis) для доработки | Пустой шаблон `flutter create` (Dart) |
| Рабочий backend + web frontend | `lib/main.dart` — демо-счётчик, `test/widget_test.dart` |
| Зависимости интеграции | только `cupertino_icons`, `flutter_lints` |
| Git-история | репозиторий **не** инициализирован под git |

**Вывод:** рабочего кода CRM нет. «Не переписывать рабочие части» неприменимо —
рабочих частей нет. Проект строится **greenfield по стеку ТЗ**. Flutter-шаблон
не удаляется и не трогается; веб-приложение живёт в каталоге [`web/`](web/).

---

## 1. ⚠️ Расхождения ТЗ ↔ официальная документация Wazzup (правило №29)

Документация сверена вживую 2026-07-19 по разделам User API v3:
`working-with-channels`, `sending-messages`, `webhooks`,
`working-with-the-user-entity`, `working-with-contacts`
(https://wazzup24.com/help/api-en/). Где ТЗ расходится с документацией —
**следуем документации**, ТЗ помечаем как неточность.

| # | Пункт ТЗ | В ТЗ | В официальной документации | Решение |
|---|---|---|---|---|
| 1 | Состояние «нужен QR» | `qridle` | Состояние канала называется **`qr`**. `qridle` — это **отдельное поле** в webhook `channelsUpdates` (не значение `state`), означающее «канал деавторизован / QR истёк» | В коде основной state = **`qr`**. `qridle` обрабатываем как доп. признак из webhook. UI-текст «Необходимо повторно отсканировать QR» вешаем на `qr` (и на `qridle`-флаг). |
| 2 | Регистр `openelsewhere` | `openelsewhere` | **`openElsewhere`** (camelCase) | Используем `openElsewhere`. Матчинг делаем регистронезависимым на всякий случай. |
| 3 | Список `state` | добавлен `unknown` | В документации `unknown` как state **отсутствует**. Полный список: `active, init?, disabled, qr, phoneUnavailable, openElsewhere, notEnoughMoney, foreignphone?, unauthorized, waitForPassword, onModeration, rejected` (последние два — WABA) | `unknown` оставляем как **локальный fallback** для любого нераспознанного значения (не падать). `init`/`foreignphone` в актуальной таблице статусов канала не описаны словесно, но упоминаются — держим как известные значения. |
| 4 | Окно идемпотентности `crmMessageId` | не указано | Дедуп-проверка **действует 60 секунд**. Повтор → `400 { error: "REPEATED_CRM_MESSAGE_ID" }` | Локальная дедупликация (уникальный индекс `organizationId+crmMessageId`) — **основная** защита; серверные 60с — вторичная. При timeout ретраим тем же `crmMessageId`; `REPEATED_CRM_MESSAGE_ID` трактуем как «возможно уже отправлено». |
| 5 | Тип сообщения `system` | есть в списке | В ENUM `type` **нет** `system`. Есть: `text, image, audio, video, document, vcard, geo, wapi_template, unsupported, missing_call, unknown` | `system` не ждём от провайдера; в нашей БД оставляем как **внутренний** тип для системных пометок CRM. Провайдерский `wapi_template` добавляем в маппинг. |
| 6 | Поле времени в `statuses` | `dateTime` | В webhook `statuses` поле называется **`timestamp`** (в `messages` — `dateTime`) | Нормализатор читает `timestamp` для статусов и `dateTime` для сообщений. |
| 7 | Направление входящего | `isEcho===false` | Подтверждено. Дополнительно у входящих `status: "inbound"` | Направление определяем по `isEcho`; `status:"inbound"` — доп. подтверждение. |
| 8 | Формат ошибки | `{error, description, data}` | Реально `{status, requestId, error, description, data}` (есть `requestId`!) | Схема ошибки включает `status` и `requestId`; `requestId` обязательно логируем. |
| 9 | Auth webhook | «Bearer WAZZUP_WEBHOOK_SECRET, если Wazzup передаёт crmKey» | Wazzup шлёт `Authorization: Bearer ${crmKey}` **только если crmKey задан в аккаунте**. `crmKey` задаётся в настройках аккаунта, а **не** в `PATCH /v3/webhooks` | Поддерживаем оба варианта: (а) заголовок `Authorization: Bearer <secret>` и (б) `?secret=` в URL. `webhooksUri` ≤ 200 символов. |
| 10 | Редактирование/удаление | edit `PATCH /v3/message/:id`, delete `DELETE /v3/message/:id` | `PATCH /v3/message/:id` подтверждён (поля `crmUserId,text,contentUri`, text/contentUri взаимоисключающие). `DELETE /v3/message/:id` — по паттерну, **подлежит финальной проверке поддержки для whatsapp перед Этапом 6/16** | Клиент реализует оба метода, но UI-кнопки скрываем, пока поддержка для `whatsapp` не подтверждена рантайм-ответом. |
| 11 | `chatType` для группы | — | Помимо `whatsapp` есть `whatsgroup` (группы). В текущей версии не используем | Жёстко фиксируем `chatType="whatsapp"`; `whatsgroup` вне scope. |

**Дополнительно подтверждено документацией (не расхождения, но важно):**
- `POST /v3/message` → **HTTP 201** `{ messageId, chatId }`. Это **только приём Wazzup**, не факт доставки клиенту.
- `text` и `contentUri` **нельзя** передавать одновременно (и при отправке, и при редактировании). Подпись к файлу = 2 отдельных сообщения с разными `crmMessageId`.
- `contentUri` скачивается провайдером **сразу и без редиректов** → signed URL можно делать короткоживущим.
- `POST /v3/users` и `POST /v3/contacts` — массив, **≤ 100** сущностей за запрос. Общий лимит API: **≤ 500 запросов / 5 сек**.
- WhatsApp-стикеры приходят как `type:"image"` со ссылкой на файл `.was`; опросы — как `type:"text"`.
- Webhook timeout со стороны Wazzup — **30 сек**; один webhook может содержать `messages` и `statuses` одновременно.

---

## 2. Целевая архитектура (потоки данных)

### 2.1 Входящее сообщение
```
Клиент → WhatsApp
   → Wazzup (QR-канал, transport=whatsapp)
   → POST /api/webhooks/wazzup (наш backend)
        • validate secret + размер body
        • сохранить raw payload + sha256  (WazzupWebhookEvent)
        • enqueue в BullMQ
        • вернуть 200 немедленно (< 30с, обычно < 50мс)
   → worker: нормализовать → upsert Contact/Conversation → insert Message (dedup)
   → скачать медиа (отдельная джоба) → S3
   → WebSocket: message.created / conversation.updated
   → интерфейс менеджера
```

### 2.2 Ответ менеджера
```
Менеджер → CRM UI → POST /api/conversations/:id/messages (наш backend)
   • auth + RBAC + доступ к диалогу
   • проверить state канала == active (иначе блок)
   • создать локальный Message (status=queued, crmMessageId=uuid)  ← ДО вызова Wazzup
   • enqueue send-job
   → worker: POST https://api.wazzup24.com/v3/message
       • 201 → сохранить wazzup messageId, status=accepted
       • REPEATED_CRM_MESSAGE_ID → уже отправлено, не дублировать
       • timeout → ретрай тем же crmMessageId
   → Wazzup доставляет клиенту
   → webhook statuses → status=sent/delivered/read/failed
   → WebSocket: message.status.updated
```

**Инвариант:** браузер **никогда** не вызывает Wazzup напрямую. `channelId` и
`crmUserId` задаются **только** на backend из сессии/конфигурации.

---

## 3. Технологический стек

> **Решение по клиенту (2026-07-19):** интерфейс менеджеров — **мобильное
> приложение на Flutter** (существующий репозиторий, iOS+Android). Веб на
> Next.js остаётся как **backend (API/WebSocket/worker) + тонкая веб-админка**
> для админ-задач (настройка/проверка webhook, страница диагностики §25).
> Полноценный веб-UI чатов из §18 не строим — его роль выполняет Flutter-приложение.

| Слой | Технология |
|---|---|
| **Мобильный клиент менеджеров** | **Flutter (Dart), iOS + Android** — чаты, composer, статусы, realtime, push |
| Backend (сервер для приложения) | Next.js Route Handlers, TS strict, Zod |
| Веб-админка (тонкая) | Next.js App Router, React, TS — только настройки/диагностика Wazzup |
| Данные | PostgreSQL + Prisma ORM |
| Очереди/кэш/lock | Redis + BullMQ |
| Realtime | Socket.IO / WebSocket (приложение и админка подписываются) |
| Auth | JWT (Bearer для мобильного приложения) + RBAC; secure cookies для админки |
| Файлы | S3-совместимое (MinIO в dev) |
| Инфра | Docker Compose, health checks, структурные логи, бэкапы БД |

**Выбор:** Next.js Route Handlers как backend (а не NestJS) — единый рантайм для
API и тонкой админки, проще деплой одной CRM одной компании. Тяжёлую фоновую
работу выносим в отдельный worker-процесс (BullMQ). Flutter-приложение общается
с backend по REST + WebSocket; аутентификация — JWT Bearer (не cookie-сессии,
т.к. клиент мобильный).

### 3.1 Топология клиентов
```
Flutter app (менеджер, iOS/Android) ──REST/JWT──▶ Next.js API ──▶ Postgres/Redis/S3
        ▲                                  │
        └──────── WebSocket (события) ──────┘
Веб-админка (Next.js, тот же backend) ── настройка webhook, диагностика §25
Worker (BullMQ) ── обработка webhook, скачивание медиа, sync
```

---

## 4. Реестр методов Wazzup (выверено по документации)

| Функция | Метод + endpoint | Ключевые поля / заметки |
|---|---|---|
| Список каналов | `GET /v3/channels` | `[{channelId, transport, plainId, state}]` |
| Отправка | `POST /v3/message` | req: `channelId*, chatType*, chatId, text|contentUri, refMessageId, crmUserId, crmMessageId, clearUnanswered`; resp 201 `{messageId, chatId}` |
| Редактирование | `PATCH /v3/message/:id` | `crmUserId, text|contentUri` (взаимоискл.) |
| Удаление | `DELETE /v3/message/:id` | проверить поддержку для whatsapp перед включением UI |
| Подписка на webhook | `PATCH /v3/webhooks` | `{webhooksUri(≤200), subscriptions{messagesAndStatuses, contactsAndDealsCreation, channelsUpdates, templateStatus}}` |
| Проверка webhook | `GET /v3/webhooks` | текущий `webhooksUri` + `subscriptions` |
| Пользователи (upsert) | `POST /v3/users` | массив `{id*, name*, phone?}`, ≤100 |
| Пользователи (список/чтение/удаление) | `GET /v3/users`, `GET /v3/users/:id`, `DELETE /v3/users/:id`, `PATCH /v3/users/bulk_delete` | — |
| Контакты (upsert) | `POST /v3/contacts` | массив `{id*, responsibleUserId*, name*, contactData*[{chatType*, chatId*}], uri?}`, ≤100 |
| Контакты (список/чтение/удаление) | `GET /v3/contacts?offset=`, `GET /v3/contacts/:id`, `DELETE /v3/contacts/:id`, `PATCH /v3/contacts/bulk_delete` | пагинация по 100, offset |

Все вызовы — только через серверный `WazzupApiClient` ([web/src/lib/wazzup/client.ts](web/src/lib/wazzup/client.ts)).

---

## 5. Состояния канала → поведение UI

| state | Отправка | Сообщение администратору |
|---|---|---|
| `active` | ✅ разрешена | — |
| `init` | ⛔ | Канал запускается |
| `qr` (+флаг `qridle`) | ⛔ | **Необходимо повторно отсканировать QR-код в Wazzup** |
| `phoneUnavailable` | ⛔ | **Wazzup потерял связь с телефоном** |
| `openElsewhere` | ⛔ | WhatsApp открыт в другом месте |
| `notEnoughMoney` | ⛔ | Канал не оплачен |
| `foreignphone` | ⛔ | QR отсканирован другим номером |
| `unauthorized` | ⛔ | **Канал WhatsApp не авторизован** |
| `waitForPassword` | ⛔ | Ожидается пароль двухфакторной аутентификации |
| `disabled` | ⛔ | Канал отключён / снят с подписки |
| `unknown`/иное | ⛔ | Неизвестное состояние канала |

При `state != active`: блокируем отправку, историю из нашей БД показываем,
показываем заметное предупреждение, уведомляем администратора.

---

## 6. Модель данных (обзор; Prisma — Этап 3)

Организации/люди: `Organization, User, Role, Permission, Team, TeamMember`.
Общение: `Contact, Conversation, ConversationAssignment, Message,
MessageStatusHistory, MessageAttachment, InternalNote, Task`.
Интеграция: `WazzupIntegration, WazzupChannel, WazzupWebhookEvent, WazzupSyncJob`.
Служебное: `Notification, AuditLog`.

Ключевые уникальные индексы:
- `Contact`: `(organizationId, channelId, chatId)` — без дублей контакта.
- `Message`: `(provider, externalMessageId)` — без дублей входящих.
- `Message`: `(organizationId, crmMessageId)` — идемпотентность исходящих.

---

## 7. Безопасность (сквозные требования)

API-ключ Wazzup — **только backend**, никогда не во frontend, маскируется в логах.
`NEXT_PUBLIC_WAZZUP_API_KEY` создавать **запрещено**. Телефоны маскируются в
системных логах. Webhook-secret защищён. Frontend не может задавать `channelId`
и `crmUserId`. Плюс: HTTPS, RBAC, secure cookies, CSRF, CORS whitelist, rate
limiting, Zod-валидация, аудит-лог, шифрование секретов.

---

## 8. Статус реализации по этапам

| Этап | Содержание | Статус |
|---|---|---|
| 1 | architecture.md, WazzupApiClient, env-валидация, GET channels, диагностика | ✅ готово |
| 2 | webhook endpoint, raw storage, очередь, нормализатор, дедуп | ✅ готово (проверено e2e на Docker) |
| 3 | Contact/Conversation/Message, входящие, realtime (WebSocket) | ✅ готово (проверено e2e на Docker) |
| 4 | **Flutter-приложение**: список диалогов, чат, composer, статусы, unread | ✅ готово (analyze 0, unit-тесты; push/медиа — позже) |
| 5 | POST /v3/message, crmMessageId, статусы, retry | ✅ готово (проверено e2e с mock Wazzup) |
| 6 | медиа (S3): входящие download→MinIO, отправка вложений, просмотр | ✅ готово (e2e); voice-плеер со скоростями — follow-up |
| 7 | JWT-логин, RBAC, захват/передача/закрытие, заметки, «печатает» | ✅ готово (e2e) |
| 8 | contacts/users sync, мониторинг (админка), тесты, hardening | ✅ готово (e2e) |

### Проверено на Этапе 2 (live, Docker)
POST `{test:true}`→200; без секрета→401; входящий текст→сохранён+обработан;
повтор webhook→`duplicate:true` (sha256-дедуп, без дубля события); входящее
сообщение дедуплицировано по `provider+externalMessageId`; `missing_call`→
подсказка; `messages`+`statuses` в одном webhook обработаны независимо;
`chatId` нормализован; телефоны в логах маскируются. 33 юнит-теста зелёные.

### Проверено на Этапе 3 (live, Docker + realtime)
4 webhook с одним `chatId` → 1 Contact, 1 Conversation, дубли не создаются;
unreadCount растёт только на входящих; авто-назначение менеджера + `Notification`
+ `AuditLog`; редактирование сохраняет `previousText`; удаление — мягкое
(`deletedAt`, «Сообщение удалено», запись не удаляется физически); статус →
`MessageStatusHistory` + обновление `Message.status`. Socket.IO раздал события
`conversation.created/assigned/updated`, `message.created/updated`,
`message.status.updated` подключённому клиенту в комнату организации. REST
`GET /api/conversations` и `.../:id/messages` отдают данные для приложения.

### Проверено на Этапе 5 (live, mock Wazzup)
Отправка менеджера: локальное сообщение создаётся `queued` с `crmMessageId` ДО
вызова Wazzup, очередь отправки вызывает `POST /v3/message` → `accepted` +
сохранён Wazzup `messageId`; статус-webhook `delivered/read` обновляет исходящее
+ пишет историю; при канале `qr` отправка блокируется (`failed` с причиной);
«Повторить» переиспользует то же сообщение и **тот же `crmMessageId`** без дубля;
`REPEATED_CRM_MESSAGE_ID` трактуется как «уже отправлено». channelId/crmUserId —
только backend. Отправка тестируется на mock (`src/scripts/mock-wazzup.ts`),
реальные WhatsApp-сообщения не уходят (§27).

### Поток отправки (§12)
```
POST /api/conversations/:id/messages/send (text[, replyToMessageId])
  → создать Message(queued, crmMessageId=uuid, direction=outbound)  ← ДО Wazzup
  → сбросить unreadCount, realtime message.created, enqueue send
send-worker → guard: канал active? → Wazzup POST /v3/message(crmMessageId)
  → 201: externalMessageId + status=accepted; realtime message.status.updated
  → REPEATED_CRM_MESSAGE_ID → already_sent (без дубля)
  → 429/5xx/timeout → BullMQ retry тем же crmMessageId
  → прочие 4xx / канал не active → failed (+ кнопка «Повторить»)
webhook statuses → sent/delivered/read/failed + MessageStatusHistory
```

### Проверено на Этапе 6 (live, MinIO + mock)
Входящее медиа: `contentUri` → отдельная джоба качает файл (follow redirects) →
проверка MIME/размера (≤50MB) + sha256 → S3/MinIO (`storageKey`), при ошибке
`status=failed` с сохранённым `originalContentUri` (§10); webhook не блокируется.
Отдача — `GET /api/attachments/:id/url` (короткий signed URL, org-проверка);
скачивание из MinIO подтверждено (HTTP 200, image/png). Исходящее вложение:
`POST /messages/send-media` (multipart) → S3 → send-worker presigned `contentUri`
→ `sendMediaMessage` (без text одновременно); подпись — отдельным сообщением
(2 crmMessageId, §14). Flutter: изображения inline + fullscreen, документы/аудио/
видео — «Открыть» (signed URL). Отправка вложений из приложения (file picker) и
voice-плеер со скоростями 1x/1.5x/2x — follow-up (backend готов).

### Проверено на Этапе 7 (live)
JWT-логин (`POST /api/auth/login`, scrypt-пароли, HS256-токен) заменил dev-заголовок
`x-user-id`; все API требуют `Authorization: Bearer` (401 без токена, 403 при
нехватке прав — RBAC admin/manager/viewer). Захват диалога атомарен: две
параллельные попытки разных менеджеров → один 200, другой **409**, ответственный
не перезаписан (§19). Передача (админ/ответственный), закрытие/переоткрытие,
внутренние заметки (`InternalNote` — отдельная таблица, send-путь её не читает,
в Wazzup не уходит). Realtime handshake верифицирует JWT; событие `user.typing`.
Доступ к чужому диалогу → 404 (org-scoped, §24/#26). Flutter: экран логина, Bearer,
меню захват/закрыть/переоткрыть, лист заметок, выход.

### Проверено на Этапе 8 (live, mock + build)
Синхронизация `POST /v3/users` и `/v3/contacts` батчами ≤100 с паузой (лимит §26),
`WazzupSyncJob` фиксирует прогон; `id` пользователя — стабильный UUID (не email).
Админ-эндпойнты (только admin, manager→403): `GET /admin/wazzup/diagnostics` (§25:
Wazzup-подключение, канал, webhook, Redis/PostgreSQL, счётчики очередей, сообщений
за 24ч, failed webhook), `GET/POST /admin/wazzup/webhooks` («Проверить»/«Настроить»),
`POST /admin/wazzup/sync`. Тонкая веб-админка `/admin/wazzup`. Hardening: middleware
с security-заголовками, rate-limit логина (10/мин → 429). `next build` — успешно.
42 backend-теста. Дальше для прод: HTTPS/домен, бэкапы БД, distributed rate-limit (Redis).

### Realtime (§23)
Worker/API публикуют события в Redis pub/sub (`realtime:events`). Отдельный
Socket.IO-сервер (`src/realtime/server.ts`, порт 3001) подписан на канал и
раздаёт события в комнаты `org:{id}` / `conv:{org}:{id}` / `user:{id}` — каждый
клиент получает только свою организацию. Аутентификация handshake — JWT (Этап 7).
