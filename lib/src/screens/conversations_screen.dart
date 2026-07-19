import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';

/// Экран списка диалогов (§18, mobile: отдельный экран списка).
class ConversationsScreen extends ConsumerWidget {
  const ConversationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(conversationsProvider);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('Диалоги'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton.filledTonal(
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(
          message: '$e',
          onRetry: () => ref.read(conversationsProvider.notifier).refresh(),
        ),
        data: (items) => RefreshIndicator(
          onRefresh: () => ref.read(conversationsProvider.notifier).refresh(),
          child: items.isEmpty
              ? _EmptyView()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Padding(
                    padding: EdgeInsets.only(left: 84),
                    child: Divider(height: 1),
                  ),
                  itemBuilder: (context, i) => _ConversationTile(items[i]),
                ),
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile(this.c);
  final Conversation c;

  @override
  Widget build(BuildContext context) {
    final sem = context.semantic;
    final time = c.lastMessageAt != null ? DateFormat('HH:mm').format(c.lastMessageAt!) : '';
    final unread = c.unreadCount > 0;

    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatScreen(conversation: c)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _Avatar(seed: c.contact.chatId ?? c.contact.name, label: c.contact.name),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.contact.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(time, style: TextStyle(fontSize: 12, color: unread ? AppColors.brand : sem.textSecondary, fontWeight: unread ? FontWeight.w600 : FontWeight.w400)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (c.assignedUser != null) ...[
                        Icon(Icons.person, size: 13, color: sem.textSecondary),
                        const SizedBox(width: 3),
                      ],
                      Expanded(
                        child: Text(
                          c.lastMessagePreview ?? 'Нет сообщений',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: sem.textSecondary, fontSize: 14),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (unread) _UnreadBadge(count: c.unreadCount),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.seed, required this.label});
  final String seed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final clean = label.replaceAll(RegExp(r'[^0-9A-Za-zА-Яа-я]'), '');
    final initial = clean.isNotEmpty ? clean.characters.last.toUpperCase() : '#';
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        gradient: avatarGradient(seed),
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: avatarGradient(seed).colors.first.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      alignment: Alignment.center,
      child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(gradient: brandGradient, borderRadius: BorderRadius.circular(12)),
      alignment: Alignment.center,
      child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class _EmptyView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final sem = context.semantic;
    return ListView(
      children: [
        const SizedBox(height: 140),
        Icon(Icons.forum_outlined, size: 64, color: sem.textSecondary.withValues(alpha: 0.5)),
        const SizedBox(height: 16),
        Center(child: Text('Пока нет диалогов', style: TextStyle(color: sem.textSecondary, fontSize: 16))),
        const SizedBox(height: 6),
        Center(child: Text('Входящие сообщения появятся здесь', style: TextStyle(color: sem.textSecondary.withValues(alpha: 0.7), fontSize: 13))),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          Padding(padding: const EdgeInsets.all(16), child: Text(message, textAlign: TextAlign.center)),
          SizedBox(width: 180, child: FilledButton(onPressed: onRetry, child: const Text('Повторить'))),
        ],
      ),
    );
  }
}
