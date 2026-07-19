import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../state/providers.dart';

/// Отображение вложения сообщения (§10, §18).
/// Изображение — превью + полноэкранный просмотр; прочее — карточка «Открыть».
class AttachmentView extends ConsumerStatefulWidget {
  const AttachmentView({super.key, required this.attachment});
  final Attachment attachment;

  @override
  ConsumerState<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends ConsumerState<AttachmentView> {
  Future<String>? _urlFuture;

  Future<String> _url() => _urlFuture ??= ref.read(apiClientProvider).attachmentUrl(widget.attachment.id);

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    if (a.status != 'stored') {
      return _statusChip(a.status == 'failed' ? 'Файл недоступен' : 'Загрузка файла…');
    }
    if (a.kind == 'image') return _imagePreview();
    return _fileCard();
  }

  Widget _statusChip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.hourglass_empty, size: 16, color: Colors.grey),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: Colors.grey)),
        ]),
      );

  Widget _imagePreview() {
    return FutureBuilder<String>(
      future: _url(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(width: 180, height: 120, child: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError || snap.data == null) {
          return _retryable('Не удалось загрузить изображение');
        }
        final url = snap.data!;
        return GestureDetector(
          onTap: () => _openFullscreen(url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              url,
              width: 200,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _retryable('Ошибка изображения'),
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const SizedBox(width: 180, height: 120, child: Center(child: CircularProgressIndicator())),
            ),
          ),
        );
      },
    );
  }

  Widget _fileCard() {
    final a = widget.attachment;
    final icon = switch (a.kind) {
      'audio' => Icons.audiotrack,
      'video' => Icons.videocam,
      'vcard' => Icons.person,
      _ => Icons.insert_drive_file,
    };
    final size = a.sizeBytes != null ? _humanSize(a.sizeBytes!) : '';
    return InkWell(
      onTap: _openExternally,
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 28),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_kindLabel(a.kind)),
              Text('${a.mimeType ?? ''} $size'.trim(),
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          const SizedBox(width: 8),
          const Icon(Icons.open_in_new, size: 18, color: Colors.blue),
        ]),
      ),
    );
  }

  Widget _retryable(String message) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(message, style: const TextStyle(color: Colors.red, fontSize: 12)),
        IconButton(
          icon: const Icon(Icons.refresh, size: 16),
          onPressed: () => setState(() => _urlFuture = null),
        ),
      ]);

  Future<void> _openExternally() async {
    try {
      final url = await _url();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось открыть файл')));
      }
    }
  }

  void _openFullscreen(String url) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: Center(child: InteractiveViewer(child: Image.network(url))),
      ),
    ));
  }

  String _kindLabel(String kind) => switch (kind) {
        'audio' => 'Аудио',
        'video' => 'Видео',
        'document' => 'Документ',
        'vcard' => 'Контакт',
        _ => 'Файл',
      };

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }
}
