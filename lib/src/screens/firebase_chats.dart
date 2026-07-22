import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/firestore_chat_repository.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';

/// Список чатов из Firestore (firebase-режим миграции).
class FirebaseConversationsScreen extends ConsumerWidget {
  const FirebaseConversationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final repo = ref.watch(firestoreChatRepositoryProvider);
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(children: [
                  Text('Чаты', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                  SizedBox(width: 8),
                  _FbBadge(),
                ]),
              ),
              Expanded(
                child: StreamBuilder<List<FsConversation>>(
                  stream: repo.watchConversations(),
                  builder: (context, snap) {
                    if (snap.hasError) return _msg(Icons.cloud_off, 'Ошибка', '${snap.error}');
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final items = snap.data!;
                    if (items.isEmpty) return _msg(Icons.forum_outlined, 'Пока нет чатов', 'Появятся после переключения вебхука');
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _tile(context, items[i], dark),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, FsConversation c, bool dark) {
    final unread = c.unreadCount > 0;
    final time = c.lastMessageAt != null ? DateFormat('HH:mm').format(c.lastMessageAt!) : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: dark ? const Color(0xFF1B242B) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FirebaseChatScreen(conversation: c))),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 50, height: 50,
                decoration: const BoxDecoration(shape: BoxShape.circle),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(flagAsset(c.phone ?? c.id), fit: BoxFit.cover),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: unread ? FontWeight.w700 : FontWeight.w600))),
                    Text(time, style: TextStyle(fontSize: 12, color: unread ? AppColors.brand : context.semantic.textSecondary)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(child: Text(c.preview ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: context.semantic.textSecondary))),
                    if (unread) Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(gradient: brandGradient, borderRadius: BorderRadius.circular(11)),
                      child: Text('${c.unreadCount}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _msg(IconData i, String t, String s) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(i, size: 54, color: AppColors.brand.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(s, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ]),
        ),
      );
}

class _FbBadge extends StatelessWidget {
  const _FbBadge();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
        child: const Text('Firebase', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFC97A0A))),
      );
}

/// Переписка одного чата из Firestore + отправка через Cloud Function.
class FirebaseChatScreen extends ConsumerStatefulWidget {
  const FirebaseChatScreen({super.key, required this.conversation});
  final FsConversation conversation;

  @override
  ConsumerState<FirebaseChatScreen> createState() => _FirebaseChatScreenState();
}

class _FirebaseChatScreenState extends ConsumerState<FirebaseChatScreen> {
  final _input = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    ref.read(firestoreChatRepositoryProvider).markRead(widget.conversation.id).catchError((_) {});
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    try {
      await ref.read(firestoreChatRepositoryProvider).sendText(
            phone: widget.conversation.phone ?? widget.conversation.id,
            text: text,
            name: widget.conversation.name,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
        _input.text = text;
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final repo = ref.watch(firestoreChatRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: Text(widget.conversation.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: Column(children: [
          Expanded(
            child: StreamBuilder<List<FsMessage>>(
              stream: repo.watchMessages(widget.conversation.id),
              builder: (context, snap) {
                if (snap.hasError) return Center(child: Text('Ошибка: ${snap.error}'));
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final msgs = snap.data!;
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) => _bubble(msgs[msgs.length - 1 - i], dark),
                );
              },
            ),
          ),
          _composer(dark),
        ]),
      ),
    );
  }

  Widget _bubble(FsMessage m, bool dark) {
    final out = m.isOutbound;
    final body = m.text ?? (m.type != 'text' ? '[${m.type}]' : '');
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: out ? AppColors.brand : (dark ? const Color(0xFF1B242B) : Colors.white),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(body, style: TextStyle(color: out ? Colors.white : (dark ? Colors.white : const Color(0xFF0E1B22)), fontSize: 15.5)),
      ),
    );
  }

  Widget _composer(bool dark) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        color: dark ? const Color(0xFF12191E) : Colors.white,
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1, maxLines: 5,
              decoration: InputDecoration(
                hintText: 'Сообщение…',
                filled: true,
                fillColor: dark ? const Color(0xFF232E36) : const Color(0xFFEDF2F2),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sending ? null : _send,
            child: Container(
              width: 46, height: 46,
              decoration: const BoxDecoration(color: AppColors.brand, shape: BoxShape.circle),
              child: _sending
                  ? const Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, color: Colors.white),
            ),
          ),
        ]),
      ),
    );
  }
}
