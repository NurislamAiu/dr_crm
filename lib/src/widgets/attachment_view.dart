import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../state/providers.dart';

const _brand = Color(0xFF13B0A0);

/// Отображение вложения (§10, §18): фото, голосовое, документ.
/// [onGradient] — пузырь исходящего (градиент) → светлые элементы.
class AttachmentView extends ConsumerStatefulWidget {
  const AttachmentView({super.key, required this.attachment, this.onGradient = false});
  final Attachment attachment;
  final bool onGradient;

  @override
  ConsumerState<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends ConsumerState<AttachmentView> {
  int _reload = 0;

  String _url() {
    final base = ref.read(appConfigProvider).apiBaseUrl;
    return '$base/api/attachments/${widget.attachment.id}/content';
  }

  Map<String, String> _headers() {
    final token = ref.read(appConfigProvider).token;
    return token != null ? {'authorization': 'Bearer $token'} : {};
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    if (a.status != 'stored') {
      return _statusChip(a.status == 'failed');
    }
    if (a.kind == 'image') return _imagePreview();
    if (a.kind == 'audio') {
      return _VoicePlayer(url: _url(), headers: _headers(), onGradient: widget.onGradient);
    }
    return _fileCard();
  }

  Widget _statusChip(bool failed) {
    final c = widget.onGradient ? Colors.white70 : Colors.grey;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(failed ? Icons.error_outline : Icons.downloading, size: 18, color: c),
        const SizedBox(width: 8),
        Text(failed ? 'Файл недоступен' : 'Загрузка…', style: TextStyle(color: c)),
      ]),
    );
  }

  Widget _imagePreview() {
    return GestureDetector(
      onTap: _openFullscreen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 258, maxHeight: 340, minWidth: 200, minHeight: 130),
          child: Image.network(
            _url(),
            key: ValueKey(_reload),
            headers: _headers(),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : Container(
                    width: 220,
                    height: 160,
                    color: Colors.black.withValues(alpha: 0.06),
                    alignment: Alignment.center,
                    child: const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.4)),
                  ),
            errorBuilder: (_, _, _) => Container(
              width: 220,
              height: 140,
              color: Colors.black.withValues(alpha: 0.06),
              alignment: Alignment.center,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.image_not_supported_outlined, color: Colors.grey),
                const SizedBox(height: 6),
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Повторить'),
                  onPressed: () => setState(() => _reload++),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fileCard() {
    final a = widget.attachment;
    final og = widget.onGradient;
    final fg = og ? Colors.white : _brand;
    final iconBg = og ? Colors.white.withValues(alpha: 0.22) : _brand.withValues(alpha: 0.12);
    final title = og ? Colors.white : const Color(0xFF10202A);
    final sub = og ? Colors.white.withValues(alpha: 0.82) : Colors.grey;
    final icon = switch (a.kind) {
      'video' => Icons.play_circle_outline,
      'vcard' => Icons.person_outline,
      _ => Icons.description_outlined,
    };
    final size = a.sizeBytes != null ? _humanSize(a.sizeBytes!) : '';
    final subtitle = [size, 'Нажмите, чтобы открыть'].where((e) => e.isNotEmpty).join(' · ');
    return InkWell(
      onTap: _openExternally,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 232,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 22, color: fg),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_kindLabel(a.kind), style: TextStyle(color: title, fontWeight: FontWeight.w600, fontSize: 14.5), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 11, color: sub), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.file_download_outlined, size: 20, color: fg),
          ]),
        ),
      ),
    );
  }

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
        body: Center(child: InteractiveViewer(child: Image.network(_url(), headers: _headers()))),
      ),
    ));
  }

  String _kindLabel(String kind) => switch (kind) {
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

/// Встроенный проигрыватель голосовых/аудио: play/пауза, дорожка, время, скорость.
class _VoicePlayer extends StatefulWidget {
  const _VoicePlayer({required this.url, required this.headers, required this.onGradient});
  final String url;
  final Map<String, String> headers;
  final bool onGradient;

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  final _player = AudioPlayer();
  bool _prepared = false;
  bool _loading = false;
  double _speed = 1.0;

  static const int _barCount = 26;
  // Псевдо-волна: детерминированные высоты по url (стабильно между кадрами).
  late final List<double> _bars = List.generate(_barCount, (i) {
    final h = (widget.url.hashCode ^ (i * 2654435761)).abs() % 100;
    return 0.28 + (h / 100) * 0.72;
  });

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _ensurePrepared() async {
    if (_prepared) return;
    setState(() => _loading = true);
    try {
      await _player.setAudioSource(AudioSource.uri(Uri.parse(widget.url), headers: widget.headers));
      _prepared = true;
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось воспроизвести')));
      }
      return;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggle() async {
    await _ensurePrepared();
    if (!_prepared) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) await _player.seek(Duration.zero);
      _player.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _seekToFraction(double f) async {
    await _ensurePrepared();
    final dur = _player.duration;
    if (dur == null) return;
    await _player.seek(dur * f.clamp(0.0, 1.0));
    if (mounted) setState(() {});
  }

  void _cycleSpeed() {
    _speed = _speed == 1.0 ? 1.5 : (_speed == 1.5 ? 2.0 : 1.0);
    _player.setSpeed(_speed);
    setState(() {});
  }

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final og = widget.onGradient;
    final circleBg = og ? Colors.white : _brand;
    final circleFg = og ? _brand : Colors.white;
    final active = og ? Colors.white : _brand;
    final muted = og ? Colors.white.withValues(alpha: 0.34) : _brand.withValues(alpha: 0.28);
    final timeColor = og ? Colors.white.withValues(alpha: 0.9) : Colors.grey.shade600;

    return SizedBox(
      width: 236,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: Row(children: [
          GestureDetector(
            onTap: _toggle,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: circleBg, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: _loading
                  ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: circleFg))
                  : Icon(_player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: circleFg, size: 26),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, snap) {
                final pos = snap.data ?? Duration.zero;
                final dur = _player.duration ?? Duration.zero;
                final progress = dur.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
                final showPos = _player.playing || pos > Duration.zero;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LayoutBuilder(
                      builder: (context, c) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => _seekToFraction(d.localPosition.dx / c.maxWidth),
                        onHorizontalDragUpdate: (d) => _seekToFraction(d.localPosition.dx / c.maxWidth),
                        child: SizedBox(
                          height: 30,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              for (var i = 0; i < _bars.length; i++)
                                Expanded(
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(horizontal: 1),
                                    height: (30 * _bars[i]).clamp(4.0, 30.0),
                                    decoration: BoxDecoration(
                                      color: ((i + 0.5) / _bars.length) <= progress ? active : muted,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.mic_none_rounded, size: 12, color: timeColor),
                      const SizedBox(width: 2),
                      Text(showPos ? _fmt(pos) : _fmt(dur), style: TextStyle(fontSize: 11, color: timeColor, height: 1)),
                    ]),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _cycleSpeed,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: og ? Colors.white.withValues(alpha: 0.20) : _brand.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text('${_speed == _speed.roundToDouble() ? _speed.toInt() : _speed}×',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: active)),
            ),
          ),
        ]),
      ),
    );
  }
}
