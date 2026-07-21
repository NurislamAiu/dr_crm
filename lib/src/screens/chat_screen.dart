import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/attachment_view.dart';

// ---- WhatsApp-стиль: цвета, фон-паттерн, пузырь с хвостиком ----
class _WA {
  static const bgLight = Color(0xFFEFEAE2);
  static const bgDark = Color(0xFF0B141A);
  static const outLight = Color(0xFFD9FDD3); // исходящий пузырь
  static const outDark = Color(0xFF005C4B);
  static const inLight = Color(0xFFFFFFFF); // входящий пузырь
  static const inDark = Color(0xFF1F2C34);
  static const textLight = Color(0xFF111B21);
  static const textDark = Color(0xFFE9EDEF);
  static const metaLight = Color(0xFF667781);
  static const metaDark = Color(0xFF8696A0);
  static const readTick = Color(0xFF53BDEB);

  static Color bg(bool d) => d ? bgDark : bgLight;
  static Color out(bool d) => d ? outDark : outLight;
  static Color inb(bool d) => d ? inDark : inLight;
  static Color txt(bool d) => d ? textDark : textLight;
  static Color meta(bool d) => d ? metaDark : metaLight;
}

/// Ненавязчивый фоновый паттерн (лёгкие «каракули»), как в WhatsApp.
class _ChatPatternPainter extends CustomPainter {
  const _ChatPatternPainter(this.dark);
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.03 : 0.035)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    const step = 64.0;
    for (double y = 20; y < size.height; y += step) {
      for (double x = 16; x < size.width; x += step) {
        final k = ((x + y) ~/ step) % 3;
        if (k == 0) {
          canvas.drawCircle(Offset(x, y), 5, paint);
        } else if (k == 1) {
          final r = Rect.fromCircle(center: Offset(x, y), radius: 6);
          canvas.drawArc(r, 0.4, 4.2, false, paint);
        } else {
          canvas.drawLine(Offset(x - 5, y + 5), Offset(x + 5, y - 5), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ChatPatternPainter old) => old.dark != dark;
}

/// Пузырь-сообщение с хвостиком (первый в группе) и мягкой тенью.
class _BubblePainter extends CustomPainter {
  const _BubblePainter({required this.color, required this.isOut, required this.tail});
  final Color color;
  final bool isOut;
  final bool tail;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const r = 12.0, tw = 7.0;
    final path = Path();

    if (isOut) {
      final br = w - tw; // правая граница тела
      path.moveTo(r, 0);
      if (tail) {
        path.lineTo(br, 0);
        path.quadraticBezierTo(br + tw, 0, w, 1);
        path.quadraticBezierTo(br + 3, 8, br, 10);
      } else {
        path.lineTo(br - r, 0);
        path.quadraticBezierTo(br, 0, br, r);
      }
      path.lineTo(br, h - r);
      path.quadraticBezierTo(br, h, br - r, h);
      path.lineTo(r, h);
      path.quadraticBezierTo(0, h, 0, h - r);
      path.lineTo(0, r);
      path.quadraticBezierTo(0, 0, r, 0);
    } else {
      final bl = tw; // левая граница тела
      path.moveTo(bl + r, 0);
      path.lineTo(w - r, 0);
      path.quadraticBezierTo(w, 0, w, r);
      path.lineTo(w, h - r);
      path.quadraticBezierTo(w, h, w - r, h);
      path.lineTo(bl + r, h);
      path.quadraticBezierTo(bl, h, bl, h - r);
      if (tail) {
        path.lineTo(bl, 10);
        path.quadraticBezierTo(bl - 3, 8, 0, 1);
        path.quadraticBezierTo(bl - tw, 0, bl + r, 0);
      } else {
        path.lineTo(bl, r);
        path.quadraticBezierTo(bl, 0, bl + r, 0);
      }
    }
    path.close();

    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.4), 1.2, false);
    canvas.drawPath(path, Paint()..color = color..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(covariant _BubblePainter old) =>
      old.color != color || old.isOut != isOut || old.tail != tail;
}

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

  // Запись голосового
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  int _recSeconds = 0;
  Timer? _recTimer;
  String? _recPath;

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
    _recTimer?.cancel();
    _recorder.dispose();
    _input.dispose();
    super.dispose();
  }

  // --- Голосовые сообщения (§18) ---
  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет доступа к микрофону')));
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      _recPath = path;
      setState(() {
        _recording = true;
        _recSeconds = 0;
      });
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recSeconds++);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Запись не началась: $e')));
    }
  }

  Future<void> _stopRecordingAndSend() async {
    _recTimer?.cancel();
    final tooShort = _recSeconds < 1;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {}
    setState(() => _recording = false);
    if (path == null || tooShort) {
      if (tooShort && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Слишком короткая запись')));
      }
      return;
    }
    setState(() => _sending = true);
    try {
      final bytes = await File(path).readAsBytes();
      await ref.read(messagesProvider(_convId).notifier).sendMedia(
            _convId,
            bytes: bytes,
            fileName: 'voice.m4a',
            mimeType: 'audio/mp4',
          );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Голосовое не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _cancelRecording() async {
    _recTimer?.cancel();
    try {
      await _recorder.stop();
      if (_recPath != null) {
        final f = File(_recPath!);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    if (mounted) setState(() => _recording = false);
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

  /// Выбор и отправка фото/файла (§14). Backend уже поддерживает вложения.
  Future<void> _pickAndSendMedia() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Фото из галереи'), onTap: () => Navigator.pop(sheet, 'gallery')),
            ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Камера'), onTap: () => Navigator.pop(sheet, 'camera')),
            ListTile(leading: const Icon(Icons.attach_file), title: const Text('Файл / документ'), onTap: () => Navigator.pop(sheet, 'file')),
          ],
        ),
      ),
    );
    if (choice == null) return;

    List<int>? bytes;
    String? name;
    String? mime;
    try {
      if (choice == 'gallery' || choice == 'camera') {
        final x = await ImagePicker().pickImage(
          source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
          imageQuality: 85,
        );
        if (x == null) return;
        bytes = await x.readAsBytes();
        name = x.name;
        mime = x.mimeType ?? _mimeFromName(x.name);
      } else {
        final res = await FilePicker.platform.pickFiles(withData: true);
        final f = res?.files.isNotEmpty == true ? res!.files.first : null;
        if (f == null || f.bytes == null) return;
        bytes = f.bytes!;
        // Расширение берём у file_picker (надёжнее, чем парсить имя).
        final ext = (f.extension ?? (f.name.contains('.') ? f.name.split('.').last : '')).toLowerCase();
        name = f.name.contains('.') || ext.isEmpty ? f.name : '${f.name}.$ext';
        mime = _mimeFromName('x.$ext');
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось выбрать файл: $e')));
      return;
    }

    setState(() => _sending = true);
    try {
      await ref.read(messagesProvider(_convId).notifier).sendMedia(
            _convId,
            bytes: bytes,
            fileName: name,
            mimeType: mime,
          );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _mimeFromName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return const {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif',
      'webp': 'image/webp', 'heic': 'image/heic', 'mp4': 'video/mp4', 'mov': 'video/quicktime',
      'pdf': 'application/pdf', 'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'mp3': 'audio/mpeg', 'ogg': 'audio/ogg', 'm4a': 'audio/mp4', 'txt': 'text/plain',
    }[ext] ?? 'application/octet-stream';
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
    final dark = Theme.of(context).brightness == Brightness.dark;

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
        color: _WA.bg(dark),
        child: CustomPaint(
          painter: _ChatPatternPainter(dark),
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
                                    tail: !prevSameSide,
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
              _Composer(
                controller: _input,
                sending: _sending,
                onSend: _send,
                onAttach: _pickAndSendMedia,
                recording: _recording,
                recSeconds: _recSeconds,
                onMicStart: _startRecording,
                onRecordStop: _stopRecordingAndSend,
                onRecordCancel: _cancelRecording,
              ),
            ],
          ),
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
  const _Bubble({required this.message, required this.tail, required this.onRetry});
  final Message message;
  final bool tail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final isOut = message.isOutbound;
    final time = DateFormat('HH:mm').format(message.sortTime);
    final textColor = _WA.txt(dark);
    final metaColor = _WA.meta(dark);
    final hasMedia = message.attachments.isNotEmpty && !message.isDeleted;

    final Widget content;
    if (message.isDeleted) {
      content = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.block, size: 15, color: metaColor),
        const SizedBox(width: 5),
        Text('Сообщение удалено', style: TextStyle(fontStyle: FontStyle.italic, color: metaColor)),
      ]);
    } else if (hasMedia) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AttachmentView(attachment: message.attachments.first),
          if (message.text != null && message.text!.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(message.text!, style: TextStyle(color: textColor, fontSize: 15))),
        ],
      );
    } else if (message.type != 'text' && (message.text == null || message.text!.isEmpty)) {
      content = Text(message.displayHint ?? _typeLabel(message.type),
          style: TextStyle(fontStyle: FontStyle.italic, color: textColor));
    } else {
      content = Text(message.text ?? '', style: TextStyle(color: textColor, fontSize: 15, height: 1.3));
    }

    // Метаданные (время/галочки/«изменено») — внизу справа, как в WhatsApp.
    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.isEdited && !message.isDeleted)
          Padding(padding: const EdgeInsets.only(right: 4), child: Text('изменено', style: TextStyle(fontSize: 10.5, color: metaColor))),
        Text(time, style: TextStyle(fontSize: 11, color: metaColor)),
        if (isOut) ...[const SizedBox(width: 3), _StatusIcon(status: message.status, meta: metaColor)],
      ],
    );

    return Container(
      alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
      padding: EdgeInsets.only(left: isOut ? 48 : 8, right: isOut ? 8 : 48, top: 1, bottom: 1),
      child: CustomPaint(
        painter: _BubblePainter(color: isOut ? _WA.out(dark) : _WA.inb(dark), isOut: isOut, tail: tail),
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.80),
          padding: EdgeInsets.only(left: isOut ? 10 : 15, right: isOut ? 15 : 10, top: 7, bottom: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Медиа/текст + мета: если контент «широкий» — мета отдельной строкой.
              content,
              const SizedBox(height: 2),
              if (isOut && message.status == 'failed')
                GestureDetector(
                  onTap: onRetry,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.refresh, size: 13, color: Colors.red),
                    const SizedBox(width: 2),
                    const Text('Повторить', style: TextStyle(fontSize: 11.5, color: Colors.red, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    meta,
                  ]),
                )
              else
                Align(alignment: Alignment.centerRight, child: meta),
            ],
          ),
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
  const _StatusIcon({required this.status, required this.meta});
  final String status;
  final Color meta;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'queued':
      case 'sending':
        return Icon(Icons.access_time, size: 14, color: meta);
      case 'accepted':
      case 'sent':
        return Icon(Icons.check, size: 16, color: meta);
      case 'delivered':
        return Icon(Icons.done_all, size: 16, color: meta);
      case 'read':
        return const Icon(Icons.done_all, size: 16, color: _WA.readTick);
      case 'failed':
        return const Icon(Icons.error_outline, size: 14, color: Colors.red);
      default:
        return const SizedBox.shrink();
    }
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttach,
    required this.recording,
    required this.recSeconds,
    required this.onMicStart,
    required this.onRecordStop,
    required this.onRecordCancel,
  });
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final bool recording;
  final int recSeconds;
  final VoidCallback onMicStart;
  final VoidCallback onRecordStop;
  final VoidCallback onRecordCancel;

  String _fmt(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      decoration: BoxDecoration(
        color: surface,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, -2))],
      ),
      padding: const EdgeInsets.fromLTRB(6, 8, 12, 10),
      child: recording ? _recordingBar(context) : _inputBar(context),
    );
  }

  Widget _recordingBar(BuildContext context) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          tooltip: 'Отменить',
          onPressed: onRecordCancel,
        ),
        const _RecDot(),
        const SizedBox(width: 8),
        Text(_fmt(recSeconds), style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(width: 8),
        Expanded(child: Text('запись…', style: TextStyle(color: context.semantic.textSecondary))),
        _CircleGradientButton(icon: Icons.send_rounded, busy: sending, onTap: sending ? null : onRecordStop),
      ],
    );
  }

  Widget _inputBar(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconButton(
          icon: Icon(Icons.add_circle_outline, color: context.semantic.textSecondary),
          tooltip: 'Прикрепить',
          onPressed: sending ? null : onAttach,
        ),
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
        // Пусто → микрофон (голосовое); есть текст → отправка.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final hasText = value.text.trim().isNotEmpty;
            return _CircleGradientButton(
              icon: hasText ? Icons.send_rounded : Icons.mic_rounded,
              busy: sending,
              onTap: sending ? null : (hasText ? onSend : onMicStart),
            );
          },
        ),
      ],
    );
  }
}

class _RecDot extends StatefulWidget {
  const _RecDot();
  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1).animate(_c),
      child: Container(width: 12, height: 12, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
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
