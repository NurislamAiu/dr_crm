import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../state/providers.dart';

/// Отображение вложения сообщения (§10, §18).
/// Изображение грузится через backend-прокси (тот же хост, что API, с Bearer) —
/// поэтому корректно показывается на устройстве/эмуляторе, а не только локально.
class AttachmentView extends ConsumerStatefulWidget {
  const AttachmentView({super.key, required this.attachment});
  final Attachment attachment;

  @override
  ConsumerState<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends ConsumerState<AttachmentView> {
  int _reload = 0;

  String get _contentUrl {
    final base = ref.read(appConfigProvider).apiBaseUrl;
    return '$base/api/attachments/${widget.attachment.id}/content';
  }

  Map<String, String> get _headers {
    final token = ref.read(appConfigProvider).token;
    return token != null ? {'authorization': 'Bearer $token'} : {};
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    if (a.status != 'stored') {
      return _chip(
        icon: a.status == 'failed' ? Icons.broken_image_outlined : Icons.downloading,
        label: a.status == 'failed' ? 'Файл недоступен' : 'Загрузка файла…',
      );
    }
    if (a.kind == 'image') return _imagePreview();
    return _fileCard();
  }

  Widget _chip({required IconData icon, required String label}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: Colors.grey)),
        ]),
      );

  Widget _imagePreview() {
    return GestureDetector(
      onTap: _openFullscreen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320, minWidth: 140, minHeight: 100),
          child: Image.network(
            _contentUrl,
            key: ValueKey(_reload),
            headers: _headers,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : Container(
                    width: 200,
                    height: 150,
                    color: Colors.black.withValues(alpha: 0.05),
                    alignment: Alignment.center,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
            errorBuilder: (_, _, _) => _errorTile(),
          ),
        ),
      ),
    );
  }

  Widget _errorTile() => Container(
        width: 200,
        height: 130,
        color: Colors.black.withValues(alpha: 0.05),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined, color: Colors.grey),
            const SizedBox(height: 6),
            TextButton.icon(
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Повторить'),
              onPressed: () => setState(() => _reload++),
            ),
          ],
        ),
      );

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
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: const Color(0xFF13B0A0).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 22, color: const Color(0xFF0E8C6D)),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_kindLabel(a.kind)),
              Text('${a.mimeType ?? ''} $size'.trim(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          const SizedBox(width: 8),
          const Icon(Icons.open_in_new, size: 18, color: Colors.blue),
        ]),
      ),
    );
  }

  /// Открытие документа/аудио/видео во внешнем приложении — по signed URL
  /// (url_launcher не умеет добавлять заголовки).
  Future<void> _openExternally() async {
    try {
      final url = await ref.read(apiClientProvider).attachmentUrl(widget.attachment.id);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось открыть файл')));
      }
    }
  }

  void _openFullscreen() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(
          child: InteractiveViewer(
            child: Image.network(_contentUrl, headers: _headers),
          ),
        ),
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
