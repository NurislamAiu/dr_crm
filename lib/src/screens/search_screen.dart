import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';

/// Поиск по диалогам (номер/имя) и по тексту сообщений.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  bool _loading = false;
  SearchResults? _results;
  int _reqId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _query = value.trim();
    _debounce?.cancel();
    if (_query.isEmpty) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), _run);
  }

  Future<void> _run() async {
    final id = ++_reqId;
    setState(() => _loading = true);
    try {
      final res = await ref.read(apiClientProvider).search(_query);
      if (id != _reqId || !mounted) return; // устарел
      setState(() {
        _results = res;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(Conversation c) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: c)));
  }

  @override
  Widget build(BuildContext context) {
    final sem = context.semantic;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Поиск: номер или текст…',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            suffixIcon: _controller.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  )
                : null,
          ),
        ),
      ),
      body: _buildBody(sem),
    );
  }

  Widget _buildBody(AppSemanticColors sem) {
    if (_query.isEmpty) {
      return _hint(Icons.search, 'Введите номер телефона или текст сообщения');
    }
    if (_loading && _results == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final r = _results;
    if (r == null || r.isEmpty) {
      return _hint(Icons.search_off, 'Ничего не найдено');
    }
    return ListView(
      children: [
        if (r.conversations.isNotEmpty) ...[
          _sectionHeader('Диалоги', r.conversations.length),
          for (final c in r.conversations) _ConversationResult(c: c, onTap: () => _open(c)),
        ],
        if (r.messages.isNotEmpty) ...[
          _sectionHeader('Сообщения', r.messages.length),
          for (final m in r.messages)
            _MessageResult(hit: m, query: _query, onTap: () => _open(m.conversation)),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _sectionHeader(String title, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text('$title · $count',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: AppColors.brand)),
      );

  Widget _hint(IconData icon, String text) {
    final sem = context.semantic;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: sem.textSecondary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: sem.textSecondary)),
          ),
        ],
      ),
    );
  }
}

class _FlagAvatar extends StatelessWidget {
  const _FlagAvatar({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: ClipOval(child: Image.asset(flagAsset(label), fit: BoxFit.cover)),
    );
  }
}

class _ConversationResult extends StatelessWidget {
  const _ConversationResult({required this.c, required this.onTap});
  final Conversation c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: _FlagAvatar(label: c.contact.chatId ?? c.contact.name),
      title: Text(c.contact.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(c.lastMessagePreview ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class _MessageResult extends StatelessWidget {
  const _MessageResult({required this.hit, required this.query, required this.onTap});
  final MessageHit hit;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sem = context.semantic;
    return ListTile(
      onTap: onTap,
      leading: _FlagAvatar(label: hit.conversation.contact.chatId ?? hit.conversation.contact.name),
      title: Text(hit.conversation.contact.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: _highlighted(hit.text ?? '', query, sem),
      trailing: Icon(hit.direction == 'outbound' ? Icons.call_made : Icons.call_received, size: 16, color: sem.textSecondary),
    );
  }

  Widget _highlighted(String text, String query, AppSemanticColors sem) {
    final lower = text.toLowerCase();
    final q = query.toLowerCase();
    final idx = lower.indexOf(q);
    if (idx < 0 || q.isEmpty) {
      return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: sem.textSecondary));
    }
    // Показываем фрагмент вокруг совпадения с подсветкой.
    final start = (idx - 20).clamp(0, text.length);
    final prefix = start > 0 ? '…' : '';
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(color: sem.textSecondary, fontSize: 13),
        children: [
          TextSpan(text: '$prefix${text.substring(start, idx)}'),
          TextSpan(
            text: text.substring(idx, idx + q.length),
            style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w700),
          ),
          TextSpan(text: text.substring(idx + q.length)),
        ],
      ),
    );
  }
}
