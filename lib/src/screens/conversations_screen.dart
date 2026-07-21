import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';
import 'leads_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

/// Экран списка диалогов (§18, mobile: отдельный экран списка).
class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key});

  @override
  ConsumerState<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // Fallback-опрос списка (подстраховка, если realtime недоступен).
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) ref.read(conversationsProvider.notifier).refresh().catchError((_) {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(conversationsProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? const [Color(0xFF0E1519), Color(0xFF0B1013)]
                : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _TopBar(
                onSearch: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SearchScreen()),
                ),
                onSettings: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
                onLeads: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LeadsScreen()),
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => _ErrorView(
                    message: '$e',
                    onRetry: () => ref.read(conversationsProvider.notifier).refresh(),
                  ),
                  data: (items) => RefreshIndicator(
                    onRefresh: () => ref.read(conversationsProvider.notifier).refresh(),
                    child: items.isEmpty
                        ? _EmptyView()
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                            itemCount: items.length,
                            itemBuilder: (context, i) => _ConversationTile(items[i]),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Верхняя панель списка: заголовок, настройки, встроенная строка поиска.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.onSearch, required this.onSettings, required this.onLeads});
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final VoidCallback onLeads;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fieldBg = dark ? const Color(0xFF1B242B) : Colors.white;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Чаты', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
              ),
              IconButton.filledTonal(
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.brand.withValues(alpha: 0.12),
                  foregroundColor: AppColors.brand,
                ),
                icon: const Icon(Icons.bolt_rounded),
                tooltip: 'Лиды',
                onPressed: onLeads,
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                icon: const Icon(Icons.settings_outlined),
                onPressed: onSettings,
              ),
            ],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onSearch,
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: fieldBg,
                borderRadius: BorderRadius.circular(14),
                boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 3))],
              ),
              child: Row(children: [
                Icon(Icons.search, size: 20, color: context.semantic.textSecondary),
                const SizedBox(width: 10),
                Text('Поиск по чатам', style: TextStyle(fontSize: 15, color: context.semantic.textSecondary)),
              ]),
            ),
          ),
          const SizedBox(height: 4),
        ],
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final time = c.lastMessageAt != null ? _smartTime(c.lastMessageAt!) : '';
    final unread = c.unreadCount > 0;
    final cardBg = dark ? const Color(0xFF1B242B) : Colors.white;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ChatScreen(conversation: c)),
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: unread ? Border.all(color: AppColors.brand.withValues(alpha: 0.30), width: 1.2) : null,
              boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: unread ? 0.07 : 0.045), blurRadius: 10, offset: const Offset(0, 3))],
            ),
            child: Row(
              children: [
                _Avatar(label: c.contact.chatId ?? c.contact.name, unread: unread, cardBg: cardBg),
                const SizedBox(width: 13),
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
                          Text(time, style: TextStyle(fontSize: 12, color: unread ? AppColors.brand : sem.textSecondary, fontWeight: unread ? FontWeight.w700 : FontWeight.w400)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          if (c.assignedUser != null) ...[
                            Icon(Icons.alternate_email, size: 13, color: sem.textSecondary),
                            const SizedBox(width: 3),
                          ],
                          Expanded(
                            child: Text(
                              c.lastMessagePreview ?? 'Нет сообщений',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: unread ? (dark ? Colors.white70 : const Color(0xFF3A464D)) : sem.textSecondary,
                                fontSize: 14,
                                fontWeight: unread ? FontWeight.w500 : FontWeight.w400,
                                height: 1.25,
                              ),
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
        ),
      ),
    );
  }

  /// Время: сегодня — ЧЧ:ММ, вчера — «вчера», раньше — дата.
  String _smartTime(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return DateFormat('HH:mm').format(t);
    if (diff == 1) return 'вчера';
    if (diff < 7) return const ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'][t.weekday - 1];
    return DateFormat('dd.MM').format(t);
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.label, this.unread = false, required this.cardBg});
  final String label;
  final bool unread;
  final Color cardBg;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: unread ? brandGradient : null,
        color: unread ? null : Colors.transparent,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 7, offset: const Offset(0, 2))],
      ),
      padding: EdgeInsets.all(unread ? 2.5 : 0),
      child: Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: cardBg),
        padding: EdgeInsets.all(unread ? 2 : 0),
        child: ClipOval(child: Image.asset(flagAsset(label), fit: BoxFit.cover)),
      ),
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
