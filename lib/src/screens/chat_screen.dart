import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../state/providers.dart';
import '../widgets/attachment_view.dart';

/// Экран чата (§18, mobile: отдельный полноэкранный чат).
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversation});
  final Conversation conversation;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  String get _convId => widget.conversation.id;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    try {
      await ref.read(messagesProvider(_convId).notifier).send(_convId, text);
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
        _input.text = text;
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _onAction(String action) async {
    try {
      await ref.read(apiClientProvider).conversationAction(_convId, action);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Готово: $action')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  Future<void> _openNotes() async {
    final api = ref.read(apiClientProvider);
    final noteController = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Внутренние заметки (не видны клиенту)',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: api.getNotes(_convId),
                  builder: (context, snap) {
                    final notes = snap.data ?? [];
                    if (notes.isEmpty) return const Text('Заметок пока нет');
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final n in notes)
                          ListTile(
                            dense: true,
                            title: Text(n['text'] as String? ?? ''),
                            subtitle: Text((n['author'] as Map?)?['name'] as String? ?? ''),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: noteController,
                      decoration: const InputDecoration(hintText: 'Новая заметка…', border: OutlineInputBorder()),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () async {
                      final text = noteController.text.trim();
                      if (text.isEmpty) return;
                      await api.addNote(_convId, text);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
    noteController.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(messagesProvider(_convId));
    ref.listen(messagesProvider(_convId), (_, _) => _scrollToBottom());

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.conversation.contact.name, style: const TextStyle(fontSize: 16)),
            if (widget.conversation.contact.phone != null)
              Text(widget.conversation.contact.phone!, style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.sticky_note_2_outlined),
            tooltip: 'Внутренние заметки',
            onPressed: _openNotes,
          ),
          PopupMenuButton<String>(
            onSelected: _onAction,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'claim', child: Text('Взять диалог')),
              PopupMenuItem(value: 'close', child: Text('Закрыть')),
              PopupMenuItem(value: 'reopen', child: Text('Переоткрыть')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Ошибка: $e')),
                data: (messages) => ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: messages.length,
                  itemBuilder: (context, i) => _Bubble(
                    message: messages[i],
                    onRetry: () => ref.read(messagesProvider(_convId).notifier).retry(_convId, messages[i].id),
                  ),
                ),
              ),
            ),
            _Composer(controller: _input, sending: _sending, onSend: _send),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.onRetry});
  final Message message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isOut = message.isOutbound;
    final align = isOut ? Alignment.centerRight : Alignment.centerLeft;
    final color = isOut ? const Color(0xFFDCF8C6) : Colors.white;
    final time = DateFormat('HH:mm').format(message.sortTime);

    final Widget content;
    if (message.isDeleted) {
      content = const Text('Сообщение удалено', style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey));
    } else if (message.attachments.isNotEmpty) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AttachmentView(attachment: message.attachments.first),
          if (message.text != null && message.text!.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(message.text!)),
        ],
      );
    } else if (message.type != 'text' && (message.text == null || message.text!.isEmpty)) {
      content = Text(message.displayHint ?? _typeLabel(message.type),
          style: const TextStyle(fontStyle: FontStyle.italic));
    } else {
      content = Text(message.text ?? '');
    }

    return Container(
      alignment: align,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10), boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 1, offset: Offset(0, 1)),
        ]),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            content,
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.isEdited && !message.isDeleted)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Text('изменено', style: TextStyle(fontSize: 10, color: Colors.grey)),
                  ),
                Text(time, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                if (isOut) ...[
                  const SizedBox(width: 4),
                  _StatusIcon(status: message.status),
                ],
                if (isOut && message.status == 'failed')
                  GestureDetector(
                    onTap: onRetry,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Text('Повторить', style: TextStyle(fontSize: 11, color: Colors.red)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _typeLabel(String type) => switch (type) {
        'image' => '📷 Изображение',
        'audio' => '🎧 Аудио',
        'video' => '🎬 Видео',
        'document' => '📄 Документ',
        'vcard' => '👤 Контакт',
        'geo' => '📍 Геолокация',
        'missing_call' => '📞 Пропущенный звонок',
        _ => 'Сообщение неподдерживаемого типа',
      };
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'queued':
      case 'sending':
        return const Icon(Icons.schedule, size: 13, color: Colors.grey);
      case 'accepted':
      case 'sent':
        return const Icon(Icons.check, size: 14, color: Colors.grey);
      case 'delivered':
        return const Icon(Icons.done_all, size: 14, color: Colors.grey);
      case 'read':
        return const Icon(Icons.done_all, size: 14, color: Colors.blue);
      case 'failed':
        return const Icon(Icons.error_outline, size: 14, color: Colors.red);
      default:
        return const SizedBox.shrink();
    }
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.sending, required this.onSend});
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Сообщение…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 6),
            FloatingActionButton.small(
              onPressed: sending ? null : onSend,
              child: sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
