import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/firebase_auth_service.dart';
import '../api/realtime_client.dart';
import '../config/app_config.dart';
import '../data/firebase_manager_service.dart';
import '../data/firestore_chat_repository.dart';
import '../data/lead_repository.dart';
import '../data/presence_service.dart';
import '../data/vip_repository.dart';
import '../models/models.dart';

/// Переопределяется в main() после загрузки настроек.
final appConfigProvider = Provider<AppConfig>((_) => throw UnimplementedError());

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(ref.watch(appConfigProvider)));

/// Репозиторий VIP-клиентов (Firestore, коллекция clients).
final vipRepositoryProvider = Provider<VipRepository>((_) => VipRepository());

/// Репозиторий лидов (Firestore, коллекция leads).
final leadRepositoryProvider = Provider<LeadRepository>((_) => LeadRepository());

/// Firebase Auth (миграция backend на Firebase).
final firebaseAuthServiceProvider = Provider<FirebaseAuthService>((_) => FirebaseAuthService());

/// Чаты поверх Firestore (миграция).
final firestoreChatRepositoryProvider = Provider<FirestoreChatRepository>((_) => FirestoreChatRepository());

/// Кэшированный стрим диалогов (одна подписка на всё приложение — без дублей чтений).
final firebaseConversationsProvider = StreamProvider<List<FsConversation>>((ref) {
  return ref.watch(firestoreChatRepositoryProvider).watchConversations();
});

/// Кэшированный стрим сообщений одного диалога (одна подписка на диалог).
final firebaseMessagesProvider = StreamProvider.autoDispose.family<List<FsMessage>, String>((ref, conversationId) {
  return ref.watch(firestoreChatRepositoryProvider).watchMessages(conversationId);
});

/// Присутствие менеджеров через Firestore (firebase-режим).
final firebasePresenceServiceProvider = Provider<FirebasePresenceService>((_) => FirebasePresenceService());

/// Управление менеджерами в firebase-режиме.
final firebaseManagerServiceProvider = Provider<FirebaseManagerService>((_) => FirebaseManagerService());

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
