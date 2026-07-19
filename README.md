# CRM — WhatsApp чаты (Flutter-приложение + backend Wazzup v3)

Внутренняя CRM одной компании: менеджеры принимают и отправляют WhatsApp-сообщения
прямо в приложении. Wazzup используется только как транспорт (канал `whatsapp`, QR).

Репозиторий содержит два компонента:

| Компонент | Путь | Что это |
|---|---|---|
| **Мобильное приложение менеджеров** | корень (`lib/`) | **Flutter** (iOS+Android): список диалогов, чат, отправка, статусы, realtime |
| **Backend + тонкая админка** | [`web/`](web/) | Next.js API/worker/Socket.IO, Prisma/Postgres, Redis/BullMQ, Wazzup-клиент |

Архитектура, сверка с официальной документацией Wazzup и статусы этапов —
в [`architecture.md`](architecture.md). Backend-инструкции — в [`web/README.md`](web/README.md).

## Мобильное приложение (Flutter)

```
lib/
├── main.dart                      # вход, гейт настройки, тема
└── src/
    ├── config/app_config.dart     # backend URL / realtime URL / dev userId (persisted)
    ├── models/models.dart         # Conversation, Message, Attachment (fromJson)
    ├── api/api_client.dart        # REST к backend (никогда напрямую к Wazzup)
    ├── api/realtime_client.dart   # Socket.IO (§23): message.created/updated/status, ...
    ├── state/providers.dart       # Riverpod: список диалогов и сообщения + realtime
    └── screens/                   # conversations, chat (composer, статусы, retry), settings
```

Возможности: список диалогов (имя, превью, время, бейдж непрочитанных, ответственный),
экран чата (входящие/исходящие, статусы доставки ✓/✓✓/read, «изменено», «удалено»,
подсказки для медиа/пропущенных звонков), composer с отправкой, «Повторить» для
неотправленных, realtime-обновления и pull-to-refresh.

### Запуск

```bash
flutter pub get
flutter run                        # выбрать устройство/эмулятор
flutter analyze                    # статический анализ (0 замечаний)
flutter test                       # unit-тесты моделей
```

При первом запуске в приложении укажите **API base URL**, **Realtime URL** и
**Manager (user) ID** (UUID менеджера из БД backend; DEV-авторизация через
заголовок `x-user-id` — Этап 7 заменит на JWT-логин). На Android-эмуляторе host
доступен как `10.0.2.2`.

### Что дальше (не входит в текущую версию приложения)
Отправка/просмотр медиа (Этап 6), запись голосовых, push-уведомления,
внутренние заметки и захват диалога (Этап 7) — по мере готовности backend.

## Быстрый старт backend

```bash
cd web
cp .env.example .env
docker compose up -d               # Postgres + Redis + MinIO
npm install && npm run db:migrate && npm run db:seed
npm run dev                        # API :3000
npm run worker                     # BullMQ worker
npm run realtime                   # Socket.IO :3001
```
