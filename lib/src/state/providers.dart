import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/firebase_auth_service.dart';
import '../api/realtime_client.dart';
import '../config/app_config.dart';
import '../data/firebase_manager_service.dart';
import '../data/firestore_chat_repository.dart';
import '../data/lead_repository.dart';
import '../data/massage_repository.dart';
import '../data/autoreply_service.dart';
import '../data/broadcast_repository.dart';
import '../data/channel_status_service.dart';
import '../data/presence_service.dart';
import '../data/push_service.dart';
import '../data/quick_replies_service.dart';
import '../data/risk_service.dart';
import '../data/session_service.dart';
import '../data/stream_retry.dart';
import '../data/vip_repository.dart';
import '../data/waba_service.dart';
import '../models/models.dart';

/// Переопределяется в main() после загрузки настроек.
final appConfigProvider = Provider<AppConfig>((_) => throw UnimplementedError());

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(ref.watch(appConfigProvider)));

/// Репозиторий VIP-клиентов (Firestore, коллекция clients).
final vipRepositoryProvider = Provider<VipRepository>((_) => VipRepository());

/// Репозиторий лидов (Firestore, коллекция leads).
final leadRepositoryProvider = Provider<LeadRepository>((_) => LeadRepository());

/// Репозиторий записей на массаж (Firestore, коллекция massages).
final massageRepositoryProvider = Provider<MassageRepository>((_) => MassageRepository());

String _digits(String? s) => (s ?? '').replaceAll(RegExp(r'\D'), '');

bool _isToday(DateTime? d) {
  if (d == null) return false;
  final n = DateTime.now();
  return d.year == n.year && d.month == n.month && d.day == n.day;
}

/// Кэшированный список лидов (одна подписка на приложение).
final leadsListProvider = StreamProvider((ref) => resilient(() => ref.watch(leadRepositoryProvider).watchAll()));

/// Кэшированный список VIP-клиентов (одна подписка на приложение).
final vipClientsListProvider = StreamProvider((ref) => resilient(() => ref.watch(vipRepositoryProvider).watchAll()));

/// Кэшированный список записей на массаж (одна подписка на приложение).
final massagesListProvider = StreamProvider((ref) => resilient(() => ref.watch(massageRepositoryProvider).watchAll()));

/// Телефоны (только цифры) активных записей на массаж — для пометки чатов.
final massagePhonesProvider = Provider<Set<String>>((ref) {
  final list = ref.watch(massagesListProvider).value ?? const [];
  return {for (final m in list) if (!m.archived && _digits(m.phone).isNotEmpty) _digits(m.phone)};
});

/// Кэшированный presence (одна подписка вместо новой на каждый rebuild).
final presenceUsersProvider =
    StreamProvider((ref) => resilient(() => ref.watch(firebasePresenceServiceProvider).watch()));

/// Кэшированный список менеджеров users/ (одна подписка).
final managersProvider =
    StreamProvider((ref) => resilient(() => ref.watch(firebaseManagerServiceProvider).watchManagers()));

/// Пуш-уведомления (FCM).
final pushServiceProvider = Provider<PushService>((_) => PushService());

/// Состояние WhatsApp-канала в Wazzup.
final channelStatusServiceProvider = Provider<ChannelStatusService>((_) => ChannelStatusService());

/// Периодическая проверка канала (сразу и далее раз в 5 минут).
final channelStatusProvider = StreamProvider<ChannelStatus>((ref) async* {
  final svc = ref.watch(channelStatusServiceProvider);
  while (true) {
    yield await svc.load();
    await Future<void>.delayed(const Duration(minutes: 5));
  }
});

/// Единственная активная сессия (один менеджер в системе).
final sessionServiceProvider = Provider<SessionService>((_) => SessionService());

/// Кто сейчас занимает систему.
final activeSessionProvider = StreamProvider((ref) => ref.watch(sessionServiceProvider).watch());

/// Включено ли правило «один менеджер в системе» (админа не касается).
final singleSessionEnabledProvider = StreamProvider((ref) => ref.watch(sessionServiceProvider).watchEnabled());

/// Журнал подозрительной активности менеджеров (только для админа).
final riskServiceProvider = Provider<RiskService>((_) => RiskService());

/// События контроля: `day` — конкретная дата (весь день), иначе `days` = 0
/// (сегодня) / 7 / 30 назад. `uid` — фильтр по менеджеру.
/// autoDispose: подписка живёт, пока открыт экран.
final riskEventsProvider =
    StreamProvider.autoDispose.family<List<RiskEvent>, ({int days, String? uid, DateTime? day})>((ref, arg) {
  final svc = ref.watch(riskServiceProvider);
  final d = arg.day;
  if (d != null) {
    final from = DateTime(d.year, d.month, d.day);
    return svc.watch(since: from, until: from.add(const Duration(days: 1)), uid: arg.uid);
  }
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final since = arg.days == 0 ? today : today.subtract(Duration(days: arg.days));
  return svc.watch(since: since, uid: arg.uid);
});

/// Свои номера клиники (не считаются «чужим номером» в сообщении).
final allowedPhonesProvider =
    StreamProvider<List<String>>((ref) => ref.watch(riskServiceProvider).watchAllowedPhones());

/// Лимит темпа отправки (config/risk).
final sendLimitsProvider =
    StreamProvider<SendLimits>((ref) => ref.watch(riskServiceProvider).watchLimits());

/// Сколько сообщений ждёт в очереди отправки.
final queueSizeProvider =
    StreamProvider.autoDispose<int>((ref) => ref.watch(riskServiceProvider).watchQueueSize());

/// Канал Wazzup и шаблоны WABA (только админ).
final wabaServiceProvider = Provider<WabaService>((_) => WabaService());

/// Настройки WABA (какой шаблон зовёт клиента в чат).
final wabaSettingsProvider =
    StreamProvider<WabaSettings>((ref) => ref.watch(wabaServiceProvider).watchSettings());

/// Серверная рассылка.
final broadcastRepositoryProvider = Provider<BroadcastRepository>((_) => BroadcastRepository());

/// Последняя рассылка (прогресс в реальном времени из Firestore).
final latestBroadcastProvider = StreamProvider((ref) => ref.watch(broadcastRepositoryProvider).watchLatest());

/// Телефоны (только цифры) активных VIP-клиентов — для пометки чатов.
final vipPhonesProvider = Provider<Set<String>>((ref) {
  final list = ref.watch(vipClientsListProvider).value ?? const [];
  return {for (final c in list) if (!c.archived && _digits(c.phone).isNotEmpty) _digits(c.phone)};
});

/// Телефоны (только цифры) активных лидов — для пометки чатов.
final leadPhonesProvider = Provider<Set<String>>((ref) {
  final list = ref.watch(leadsListProvider).value ?? const [];
  return {for (final l in list) if (!l.archived && _digits(l.phone).isNotEmpty) _digits(l.phone)};
});

/// Сколько лидов создано сегодня.
final leadsTodayCountProvider = Provider<int>((ref) {
  final list = ref.watch(leadsListProvider).value ?? const [];
  return list.where((l) => !l.archived && _isToday(l.createdAt)).length;
});


/// Firebase Auth (миграция backend на Firebase).
final firebaseAuthServiceProvider = Provider<FirebaseAuthService>((_) => FirebaseAuthService());

/// Чаты поверх Firestore (миграция).
final firestoreChatRepositoryProvider = Provider<FirestoreChatRepository>((_) => FirestoreChatRepository());

/// Кэшированный стрим диалогов (одна подписка на всё приложение — без дублей чтений).
final firebaseConversationsProvider = StreamProvider<List<FsConversation>>((ref) {
  return resilient(() => ref.watch(firestoreChatRepositoryProvider).watchConversations());
});

/// Кэшированный стрим сообщений одного диалога (одна подписка на диалог).
final firebaseMessagesProvider = StreamProvider.autoDispose.family<List<FsMessage>, String>((ref, conversationId) {
  return resilient(() => ref.watch(firestoreChatRepositoryProvider).watchMessages(conversationId));
});

/// Присутствие менеджеров через Firestore (firebase-режим).
final firebasePresenceServiceProvider = Provider<FirebasePresenceService>((_) => FirebasePresenceService());

/// Управление менеджерами в firebase-режиме.
final firebaseManagerServiceProvider = Provider<FirebaseManagerService>((_) => FirebaseManagerService());

/// Быстрые ответы (шаблоны сообщений, Firestore).
final quickRepliesServiceProvider = Provider<QuickRepliesService>((_) => QuickRepliesService());

/// Кэшированный стрим быстрых ответов.
final quickRepliesProvider = StreamProvider<List<QuickReply>>((ref) {
  return ref.watch(quickRepliesServiceProvider).watch();
});

/// Автоответчик (Firestore config/autoReply).
final autoReplyServiceProvider = Provider<AutoReplyService>((_) => AutoReplyService());

/// Онлайн-менеджер (присутствие в системе).
class OnlineUser {
  const OnlineUser(this.userId, this.userName);
  final String userId;
  final String userName;
}

/// Кто сейчас в системе (обновляется realtime-событием presence.updated).
class PresenceNotifier extends Notifier<List<OnlineUser>> {
  StreamSubscription<RealtimeEvent>? _sub;

  @override
  List<OnlineUser> build() {
    final rt = ref.watch(realtimeClientProvider);
    _sub = rt.events.listen((e) {
      if (e.event != 'presence.updated') return;
      final users = (e.payload['users'] as List?) ?? const [];
      state = [
        for (final u in users)
          if (u is Map) OnlineUser((u['userId'] ?? '').toString(), (u['userName'] ?? '').toString()),
      ];
    });
    ref.onDispose(() => _sub?.cancel());
    return const [];
  }
}

final presenceProvider = NotifierProvider<PresenceNotifier, List<OnlineUser>>(PresenceNotifier.new);

final realtimeClientProvider = Provider<RealtimeClient>((ref) {
  final client = RealtimeClient(ref.watch(appConfigProvider));
  client.connect();
  ref.onDispose(client.dispose);
  return client;
});

/// Список диалогов. Обновляется при realtime-событиях (§23).
class ConversationsNotifier extends AsyncNotifier<List<Conversation>> {
  StreamSubscription<RealtimeEvent>? _sub;

  @override
  Future<List<Conversation>> build() async {
    final rt = ref.watch(realtimeClientProvider);
    _sub = rt.events.listen((e) {
      switch (e.event) {
        case 'conversation.created':
        case 'conversation.updated':
        case 'conversation.assigned':
        case 'message.created':
        case 'message.status.updated':
          _refreshSoon();
      }
    });
    ref.onDispose(() => _sub?.cancel());
    return ref.read(apiClientProvider).getConversations();
  }

  Timer? _debounce;
  void _refreshSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), refresh);
  }

  Future<void> refresh() async {
    final data = await ref.read(apiClientProvider).getConversations();
    state = AsyncData(data);
  }
}

final conversationsProvider =
    AsyncNotifierProvider<ConversationsNotifier, List<Conversation>>(ConversationsNotifier.new);

/// Сообщения одного диалога с realtime-обновлением.
class MessagesNotifier extends FamilyAsyncNotifier<List<Message>, String> {
  StreamSubscription<RealtimeEvent>? _sub;

  @override
  Future<List<Message>> build(String conversationId) async {
    final rt = ref.watch(realtimeClientProvider);
    rt.subscribeConversation(conversationId);
    _sub = rt.events.listen((e) => _onEvent(conversationId, e));
    ref.onDispose(() {
      _sub?.cancel();
      rt.unsubscribeConversation(conversationId);
    });
    return ref.read(apiClientProvider).getMessages(conversationId);
  }

  void _onEvent(String conversationId, RealtimeEvent e) {
    if (e.conversationId != null && e.conversationId != conversationId) return;
    final current = state.valueOrNull;
    if (current == null) return;

    switch (e.event) {
      case 'message.created':
        // Полную запись подтянем refresh'ем — realtime payload краткий.
        _refreshSoon(conversationId);
      case 'message.status.updated':
        final id = e.payload['messageId'] as String?;
        final status = e.payload['status'] as String?;
        if (id != null && status != null) {
          final updated = [
            for (final m in current)
              if (m.id == id) (m..status = status) else m,
          ];
          state = AsyncData(updated);
        }
      case 'message.updated':
        _refreshSoon(conversationId);
    }
  }

  Timer? _debounce;
  void _refreshSoon(String conversationId) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => refresh(conversationId));
  }

  Future<void> refresh(String conversationId) async {
    final data = await ref.read(apiClientProvider).getMessages(conversationId);
    state = AsyncData(data);
  }

  Future<void> send(String conversationId, String text, {String? replyToMessageId}) async {
    await ref.read(apiClientProvider).sendMessage(conversationId, text, replyToMessageId: replyToMessageId);
    await refresh(conversationId);
  }

  Future<void> sendMedia(
    String conversationId, {
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    String? caption,
  }) async {
    await ref.read(apiClientProvider).sendMedia(conversationId,
        bytes: bytes, fileName: fileName, mimeType: mimeType, caption: caption);
    await refresh(conversationId);
  }

  Future<void> retry(String conversationId, String messageId) async {
    await ref.read(apiClientProvider).retryMessage(messageId);
    await refresh(conversationId);
  }

  Future<void> edit(String conversationId, String messageId, String text) async {
    await ref.read(apiClientProvider).editMessage(messageId, text);
    await refresh(conversationId);
  }

  Future<void> remove(String conversationId, String messageId) async {
    await ref.read(apiClientProvider).deleteMessage(messageId);
    await refresh(conversationId);
  }
}

final messagesProvider =
    AsyncNotifierProvider.family<MessagesNotifier, List<Message>, String>(MessagesNotifier.new);
