import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
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
  bool _sending = false;
  Timer? _poll;

  String get _convId => widget.conversation.id;

  @override
  void initState() {
    super.initState();
    // Открыли чат → отмечаем прочитанным; список обновится по realtime.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(apiClientProvider).markRead(_convId).then((_) {
        if (mounted) ref.read(conversationsProvider.notifier).refresh();
      }).catchError((_) {});
    });
    // Fallback-опрос: если realtime недоступен (напр. другой хост), чат всё равно
    // обновляется. При активном realtime это лишь редкая подстраховка.
    _poll = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) ref.read(messagesProvider(_convId).notifier).refresh(_convId).catchError((_) {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    try {
      await ref.read(messagesProvider(_convId).notifier).send(_convId, text);
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

  static const _sentStatuses = {'accepted', 'sent', 'delivered', 'read'};

  /// Меню действий над сообщением (изменить/удалить — только своё отправленное, §16).
  void _showMessageActions(Message m) {
    final canEditDelete = m.isOutbound && !m.isDeleted && _sentStatuses.contains(m.status);
    if (!canEditDelete && (m.text == null || m.text!.isEmpty)) return;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.text != null && m.text!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Копировать'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: m.text!));
                  Navigator.pop(sheet);
                },
              ),
            if (canEditDelete) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Изменить'),
                onTap: () {
                  Navigator.pop(sheet);
                  _editMessage(m);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('Удалить', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(sheet);
                  _deleteMessage(m);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _editMessage(Message m) async {
    // Диалог владеет своим контроллером (не освобождаем во время анимации закрытия).
    final newText = await showDialog<String>(
      context: context,
      builder: (_) => _EditMessageDialog(initial: m.text ?? ''),
    );
    if (newText == null || newText.isEmpty || newText == m.text) return;
    try {
      await ref.read(messagesProvider(_convId).notifier).edit(_convId, m.id, newText);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не изменено: $e')));
    }
  }

  Future<void> _deleteMessage(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Удалить сообщение?'),
        content: const Text('Сообщение будет удалено и у клиента в WhatsApp.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(messagesProvider(_convId).notifier).remove(_convId, m.id);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалено: $e')));
    }
  }

  Future<void> _openNotes() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _NotesSheet(conversationId: _convId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(messagesProvider(_convId));
    final brightness = Theme.of(context).brightness;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 6, offset: const Offset(0, 2))],
              ),
              child: ClipOval(
                child: Image.asset(
                  flagAsset(widget.conversation.contact.chatId ?? widget.conversation.contact.name),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.conversation.contact.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                  if (widget.conversation.contact.phone != null)
                    Text(widget.conversation.contact.phone!, style: TextStyle(fontSize: 12, color: context.semantic.textSecondary, fontWeight: FontWeight.w400)),
                ],
              ),
            ),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'claim', child: Text('Взять диалог')),
              PopupMenuItem(value: 'close', child: Text('Закрыть')),
              PopupMenuItem(value: 'reopen', child: Text('Переоткрыть')),
            ],
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(gradient: chatBackground(brightness)),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: async.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Ошибка: $e')),
                  data: (messages) => messages.isEmpty
                    ? const _EmptyChat()
                    // reverse: true — чат закреплён внизу на последнем сообщении;
                    // новые приходят снизу, ручной скролл не нужен. Индексируем
                    // с конца: reverse-индекс 0 = самое новое (низ).
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemCount: messages.length,
                        itemBuilder: (context, i) {
                          final idx = messages.length - 1 - i;
                          final m = messages[idx];
                          final showDate = idx == 0 || !_sameDay(messages[idx - 1].sortTime, m.sortTime);
                          final prevSameSide = idx > 0 &&
                              !showDate &&
                              messages[idx - 1].isOutbound == m.isOutbound;
                          return Column(
                            children: [
                              if (showDate) _DateChip(date: m.sortTime),
                              Padding(
                                padding: EdgeInsets.only(top: prevSameSide ? 1 : 4),
                                child: GestureDetector(
                                  onLongPress: () => _showMessageActions(m),
                                  child: _Bubble(
                                    message: m,
                                    onRetry: () => ref.read(messagesProvider(_convId).notifier).retry(_convId, m.id),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                ),
              ),
              _Composer(controller: _input, sending: _sending, onSend: _send),
            ],
          ),
        ),
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String _dateLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  const months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
  final year = d.year != now.year ? ' ${d.year}' : '';
  return '${d.day} ${months[d.month - 1]}$year';
}

/// Разделитель дат в переписке.
class _DateChip extends StatelessWidget {
  const _DateChip({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: dark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _dateLabel(date),
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.semantic.textSecondary),
      ),
    );
  }
}

/// Пустая переписка.
class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final sem = context.semantic;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(color: AppColors.brand.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: const Icon(Icons.forum_outlined, size: 40, color: AppColors.brand),
          ),
          const SizedBox(height: 16),
          Text('Начните переписку', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: sem.textSecondary)),
          const SizedBox(height: 4),
          Text('Сообщения появятся здесь', style: TextStyle(fontSize: 13, color: sem.textSecondary.withValues(alpha: 0.7))),
        ],
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
    final sem = context.semantic;
    final isOut = message.isOutbound;
    final time = DateFormat('HH:mm').format(message.sortTime);
    final onGrad = isOut; // текст на градиенте — светлый
    final textColor = isOut ? Colors.white : Theme.of(context).textTheme.bodyMedium!.color;
    final metaColor = isOut ? Colors.white.withValues(alpha: 0.8) : sem.textSecondary;

    final Widget content;
    if (message.isDeleted) {
      content = Text('Сообщение удалено',
          style: TextStyle(fontStyle: FontStyle.italic, color: metaColor));
    } else if (message.attachments.isNotEmpty) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AttachmentView(attachment: message.attachments.first),
          if (message.text != null && message.text!.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(message.text!, style: TextStyle(color: textColor))),
        ],
      );
    } else if (message.type != 'text' && (message.text == null || message.text!.isEmpty)) {
      content = Text(message.displayHint ?? _typeLabel(message.type),
          style: TextStyle(fontStyle: FontStyle.italic, color: textColor));
    } else {
      content = Text(message.text ?? '', style: TextStyle(color: textColor, fontSize: 15, height: 1.3));
    }

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(isOut ? 18 : 5),
      bottomRight: Radius.circular(isOut ? 5 : 18),
    );

    return Container(
      alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          gradient: isOut ? brandGradient : null,
          color: isOut ? null : sem.bubbleIn,
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: isOut ? AppColors.brand.withValues(alpha: 0.28) : Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            content,
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.isEdited && !message.isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text('изменено', style: TextStyle(fontSize: 10, color: metaColor)),
                  ),
                Text(time, style: TextStyle(fontSize: 10.5, color: metaColor)),
                if (isOut) ...[
                  const SizedBox(width: 4),
                  _StatusIcon(status: message.status, onGradient: onGrad),
                ],
                if (isOut && message.status == 'failed')
                  GestureDetector(
                    onTap: onRetry,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Row(mainAxisSize: MainAxisSize.min, children: const [
                        Icon(Icons.refresh, size: 12, color: Colors.white),
                        SizedBox(width: 2),
                        Text('Повторить', style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                      ]),
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
  const _StatusIcon({required this.status, required this.onGradient});
  final String status;
  final bool onGradient;

  @override
  Widget build(BuildContext context) {
    final base = onGradient ? Colors.white.withValues(alpha: 0.85) : Colors.grey;
    switch (status) {
      case 'queued':
      case 'sending':
        return Icon(Icons.schedule, size: 13, color: base);
      case 'accepted':
      case 'sent':
        return Icon(Icons.check, size: 15, color: base);
      case 'delivered':
        return Icon(Icons.done_all, size: 15, color: base);
      case 'read':
        return Icon(Icons.done_all, size: 15, color: onGradient ? const Color(0xFF9BE7FF) : Colors.blue);
      case 'failed':
        return Icon(Icons.error_outline, size: 14, color: onGradient ? Colors.white : Colors.red);
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
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      decoration: BoxDecoration(
        color: surface,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, -2))],
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: 'Сообщение…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _CircleGradientButton(
            icon: Icons.send_rounded,
            busy: sending,
            onTap: sending ? null : onSend,
          ),
        ],
      ),
    );
  }
}

/// Круглая градиентная кнопка (отправка / добавить заметку).
class _CircleGradientButton extends StatelessWidget {
  const _CircleGradientButton({required this.icon, this.onTap, this.busy = false});
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          gradient: brandGradient,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: AppColors.brand.withValues(alpha: 0.4), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        alignment: Alignment.center,
        child: busy
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

/// Диалог изменения сообщения — сам владеет контроллером (безопасно при закрытии).
class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.initial});
  final String initial;

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Изменить сообщение'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 6,
        decoration: const InputDecoration(hintText: 'Текст сообщения…'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, _controller.text.trim()), child: const Text('Сохранить')),
      ],
    );
  }
}

/// Лист внутренних заметок — владеет контроллером и Future списка.
class _NotesSheet extends ConsumerStatefulWidget {
  const _NotesSheet({required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<_NotesSheet> createState() => _NotesSheetState();
}

class _NotesSheetState extends ConsumerState<_NotesSheet> {
  final _controller = TextEditingController();
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(apiClientProvider).getNotes(widget.conversationId);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    await ref.read(apiClientProvider).addNote(widget.conversationId, text);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.lock_outline, size: 18, color: AppColors.brand),
                const SizedBox(width: 8),
                Text('Внутренние заметки', style: Theme.of(context).textTheme.titleMedium),
              ]),
              const SizedBox(height: 2),
              Text('Не видны клиенту', style: TextStyle(color: context.semantic.textSecondary, fontSize: 12)),
              const SizedBox(height: 12),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _future,
                builder: (context, snap) {
                  final notes = snap.data ?? [];
                  if (notes.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Заметок пока нет', style: TextStyle(color: context.semantic.textSecondary)),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final n in notes)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: AppColors.brand.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(n['text'] as String? ?? ''),
                              const SizedBox(height: 2),
                              Text((n['author'] as Map?)?['name'] as String? ?? '',
                                  style: TextStyle(fontSize: 11, color: context.semantic.textSecondary)),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: _controller, decoration: const InputDecoration(hintText: 'Новая заметка…'))),
                const SizedBox(width: 8),
                _CircleGradientButton(icon: Icons.add, onTap: _add),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
