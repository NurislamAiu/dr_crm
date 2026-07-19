import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/realtime_client.dart';
import '../config/app_config.dart';
import '../models/models.dart';

/// Переопределяется в main() после загрузки настроек.
final appConfigProvider = Provider<AppConfig>((_) => throw UnimplementedError());

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(ref.watch(appConfigProvider)));

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

  Future<void> retry(String conversationId, String messageId) async {
    await ref.read(apiClientProvider).retryMessage(messageId);
    await refresh(conversationId);
  }
}

final messagesProvider =
    AsyncNotifierProvider.family<MessagesNotifier, List<Message>, String>(MessagesNotifier.new);
