import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/app_theme.dart';

const _defaultTemplate = '''Здравствуйте, {name}!
DR.TOITAYEV: напоминаем, что {date} у Вас запись к врачу.
Для подтверждения, переноса или отмены записи напишите нам в WhatsApp на номер +7 777 175 44 45''';

const _delaySeconds = 20;

enum _St { pending, sending, sent, failed }

class _Row {
  _Row({required this.name, required this.phone, required this.date});
  final String name;
  final String phone;
  final String date;
  _St status = _St.pending;
  String? error;
}

/// Экран массовой рассылки сервисных напоминаний (§14 — обычная отправка через
/// Wazzup, пауза 20 c между контактами против блокировки номера).
class BroadcastScreen extends ConsumerStatefulWidget {
  const BroadcastScreen({super.key});

  @override
  ConsumerState<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends ConsumerState<BroadcastScreen> {
  final _template = TextEditingController(text: _defaultTemplate);
  final _contacts = TextEditingController();

  List<_Row> _rows = [];
  bool _running = false;
  bool _stop = false;
  int _countdown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _template.dispose();
    _contacts.dispose();
    super.dispose();
  }

  List<_Row> _parse() {
    return _contacts.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map((line) {
          final sep = line.contains(';') ? ';' : ',';
          final parts = line.split(sep);
          return _Row(
            name: parts.isNotEmpty ? parts[0].trim() : '',
            phone: parts.length > 1 ? parts[1].trim() : '',
            date: parts.length > 2 ? parts[2].trim() : '',
          );
        })
        .where((r) => r.phone.isNotEmpty)
        .toList();
  }

  Future<void> _sleepCountdown() async {
    final completer = Completer<void>();
    _countdown = _delaySeconds;
    if (mounted) setState(() {});
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      _countdown--;
      if (_countdown <= 0 || _stop) {
        t.cancel();
        if (!completer.isCompleted) completer.complete();
      }
      if (mounted) setState(() {});
    });
    return completer.future;
  }

  Future<void> _start() async {
    final rows = _parse();
    if (rows.isEmpty) return;
    setState(() {
      _rows = rows;
      _running = true;
      _stop = false;
    });
    final api = ref.read(apiClientProvider);

    for (var i = 0; i < rows.length; i++) {
      if (_stop) break;
      setState(() => rows[i].status = _St.sending);
      final text = _template.text.replaceAll('{name}', rows[i].name).replaceAll('{date}', rows[i].date);
      try {
        final res = await api.broadcastSend(name: rows[i].name, phone: rows[i].phone, text: text);
        final ok = res['ok'] == true;
        setState(() {
          rows[i].status = ok ? _St.sent : _St.failed;
          rows[i].error = ok ? null : (res['error'] as String?);
        });
      } catch (e) {
        setState(() {
          rows[i].status = _St.failed;
          rows[i].error = '$e';
        });
      }
      if (i < rows.length - 1 && !_stop) await _sleepCountdown();
    }
    _timer?.cancel();
    if (mounted) {
      setState(() {
        _running = false;
        _countdown = 0;
      });
    }
  }

  void _stopRun() => setState(() => _stop = true);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final parsedCount = _running ? _rows.length : _parse().length;
    final sent = _rows.where((r) => r.status == _St.sent).length;
    final failed = _rows.where((r) => r.status == _St.failed).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Рассылка', style: TextStyle(fontWeight: FontWeight.w800))),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          children: [
            _hint(dark),
            _card(dark, 'Текст сообщения', Icons.message_rounded, [
              Text('Переменные: {name} — имя, {date} — дата приёма',
                  style: TextStyle(fontSize: 12, color: context.semantic.textSecondary)),
              const SizedBox(height: 8),
              _multiline(dark, _template, minLines: 4, mono: false, enabled: !_running),
            ]),
            _card(dark, 'Контакты', Icons.people_alt_rounded, [
              Text('По одному в строке:  Имя;+7XXXXXXXXXX;дата',
                  style: TextStyle(fontSize: 12, color: context.semantic.textSecondary)),
              const SizedBox(height: 8),
              _multiline(dark, _contacts, minLines: 5, mono: true, enabled: !_running,
                  hint: 'Дархан;+77014004647;22 июля\nАйгуль;+77771234567;23 июля'),
              const SizedBox(height: 8),
              Text('Распознано: $parsedCount', style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 4),
            _actionBar(dark, parsedCount, sent, failed),
            if (_rows.isNotEmpty) ...[
              const SizedBox(height: 12),
              _progress(dark),
            ],
          ],
        ),
      ),
    );
  }

  Widget _hint(bool dark) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.brand.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.brand.withValues(alpha: 0.25)),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.brand),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Между сообщениями пауза 20 секунд — так WhatsApp не блокирует номер за массовую отправку.',
                style: TextStyle(fontSize: 12.5, color: dark ? Colors.white70 : const Color(0xFF12403A))),
          ),
        ]),
      );

  Widget _card(bool dark, String title, IconData icon, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF1B242B) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 10, offset: const Offset(0, 3))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(color: AppColors.brand.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, size: 16, color: AppColors.brand),
              ),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
            ]),
          ),
          ...children,
        ]),
      );

  Widget _multiline(bool dark, TextEditingController c, {required int minLines, required bool mono, required bool enabled, String? hint}) {
    return TextField(
      controller: c,
      enabled: enabled,
      minLines: minLines,
      maxLines: minLines + 6,
      style: TextStyle(fontSize: 14.5, fontFamily: mono ? 'monospace' : null, height: 1.35),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontFamily: mono ? 'monospace' : null, color: Colors.grey.withValues(alpha: 0.6)),
        filled: true,
        fillColor: dark ? const Color(0xFF232E36) : const Color(0xFFF4F6F8),
        contentPadding: const EdgeInsets.all(12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brand, width: 1.5)),
      ),
    );
  }

  Widget _actionBar(bool dark, int parsedCount, int sent, int failed) {
    return Row(children: [
      Expanded(
        child: SizedBox(
          height: 50,
          child: _running
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  onPressed: _stopRun,
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(_countdown > 0 ? 'Остановить · следующая через $_countdown c' : 'Остановить'),
                )
              : FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  onPressed: parsedCount > 0 ? _start : null,
                  icon: const Icon(Icons.send_rounded),
                  label: Text('Отправить рассылку ($parsedCount)', style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
        ),
      ),
      if (_rows.isNotEmpty) ...[
        const SizedBox(width: 12),
        Text('✅ $sent  ❌ $failed', style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    ]);
  }

  Widget _progress(bool dark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1B242B) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(
        children: [
          for (var i = 0; i < _rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: i < _rows.length - 1
                    ? Border(bottom: BorderSide(color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.06)))
                    : null,
              ),
              child: Row(children: [
                _statusIcon(_rows[i].status),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(_rows[i].name.isEmpty ? '—' : _rows[i].name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                      const SizedBox(width: 6),
                      Flexible(child: Text(_rows[i].phone, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.semantic.textSecondary, fontSize: 13))),
                    ]),
                    if (_rows[i].date.isNotEmpty)
                      Text(_rows[i].date, style: TextStyle(fontSize: 12, color: context.semantic.textSecondary)),
                    if (_rows[i].error != null)
                      Text(_rows[i].error!, style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
                  ]),
                ),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _statusIcon(_St s) => switch (s) {
        _St.sent => const Icon(Icons.check_circle_rounded, color: Color(0xFF2E9E5B), size: 22),
        _St.failed => Icon(Icons.error_rounded, color: Colors.red.shade400, size: 22),
        _St.sending => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.brand)),
        _St.pending => Icon(Icons.schedule_rounded, color: Colors.grey.shade400, size: 22),
      };
}
