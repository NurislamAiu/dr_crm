import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/app_theme.dart';

const _phone = '+7 777 175 44 45';

/// 10 вариантов текста — каждому контакту уходит по очереди, чтобы WhatsApp
/// не принял одинаковые сообщения за спам. Переменные {name} и {date}.
const _defaultVariants = <String>[
  'Здравствуйте, {name}!\nDR.TOITAYEV: напоминаем, что {date} у Вас запись к врачу.\nДля подтверждения, переноса или отмены записи напишите нам в WhatsApp или на рабочий номер клиники $_phone',
  'Добрый день, {name}!\nКлиника DR.TOITAYEV напоминает о Вашем приёме {date}. Подтвердить, перенести или отменить визит можно ответом в этот чат или по номеру $_phone',
  '{name}, здравствуйте!\nНапоминаем, что {date} Вас ждёт приём у врача в клинике DR.TOITAYEV. Подтвердить или изменить запись — напишите в WhatsApp либо позвоните: $_phone',
  'Здравствуйте, {name}!\nЭто клиника DR.TOITAYEV. Ваш приём назначен на {date}. Пожалуйста, подтвердите визит — а если нужно перенести или отменить, напишите нам сюда или на $_phone',
  'Добрый день, {name}!\nНапоминаем: {date} у Вас визит к врачу в DR.TOITAYEV. Для подтверждения, переноса или отмены ответьте в этот чат или позвоните $_phone',
  '{name}, добрый день!\nКлиника DR.TOITAYEV ждёт Вас на приёме {date}. Чтобы подтвердить запись, перенести или отменить — свяжитесь с нами в WhatsApp или по телефону $_phone',
  'Здравствуйте, {name}!\nНапоминаем о Вашей записи к врачу {date} (DR.TOITAYEV). Подтвердите, пожалуйста, визит. По вопросам переноса и отмены — WhatsApp или номер клиники $_phone',
  'Уважаемый(ая) {name}!\nНапоминаем, что {date} у Вас запланирован приём в клинике DR.TOITAYEV. Подтвердить или изменить запись можно здесь в WhatsApp или по номеру $_phone',
  'Здравствуйте, {name}!\nDR.TOITAYEV напоминает: приём у врача — {date}. Просим подтвердить визит. Перенос или отмена — напишите нам в WhatsApp либо позвоните $_phone',
  'Добрый день, {name}!\nЖдём Вас {date} на приёме в клинике DR.TOITAYEV. Для подтверждения, переноса или отмены записи ответьте в этот чат или на рабочий номер $_phone',
];

/// Шаблон запроса предоплаты (реквизиты — точь-в-точь как дал клиент).
const _paymentTemplate = '''Здравствуйте, для подтверждения записи необходимо внести предоплату

ВТБ Россия

2204 3603 0004 5901

ALIYA BAIKENOVA

После внесения предоплаты отправьте чек, имя и контакт пациента.
В случае отмены записи, предоплата не возвращается!''';

const _delaySeconds = 20;

/// Как выбирать вариант текста для каждого контакта.
enum _Mode { rotate, random, single }

enum _St { pending, sending, sent, failed }

class _Row {
  _Row({required this.name, required this.phone, required this.date});
  final String name;
  final String phone;
  final String date;
  int variant = 0; // номер использованного варианта (1..N)
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
  final List<TextEditingController> _variants =
      _defaultVariants.map((t) => TextEditingController(text: t)).toList();
  final _contacts = TextEditingController();

  List<_Row> _rows = [];
  bool _running = false;
  bool _stop = false;
  int _countdown = 0;
  Timer? _timer;

  _Mode _mode = _Mode.rotate;
  int _singleIndex = 0; // выбранный вариант в режиме «Один»
  final _rnd = Random();

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _variants) {
      c.dispose();
    }
    _contacts.dispose();
    super.dispose();
  }

  List<String> _activeVariants() => _variants.map((c) => c.text).where((t) => t.trim().isNotEmpty).toList();

  void _addVariant() => setState(() => _variants.add(TextEditingController()));

  /// Загрузить пресет текстов (заменяет текущие варианты).
  void _loadPreset(List<String> texts, {required bool single}) {
    setState(() {
      for (final c in _variants) {
        c.dispose();
      }
      _variants
        ..clear()
        ..addAll(texts.map((t) => TextEditingController(text: t)));
      _singleIndex = 0;
      _mode = single ? _Mode.single : _Mode.rotate;
    });
  }

  void _removeVariant(int i) {
    setState(() {
      final c = _variants.removeAt(i);
      c.dispose();
    });
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
    final variants = _activeVariants();
    if (rows.isEmpty || variants.isEmpty) return;
    // В режиме «Один» берём выбранный вариант (если пуст — не стартуем).
    final single = _mode == _Mode.single ? _variants[_singleIndex].text : null;
    if (_mode == _Mode.single && (single == null || single.trim().isEmpty)) return;

    setState(() {
      _rows = rows;
      _running = true;
      _stop = false;
    });
    final api = ref.read(apiClientProvider);

    for (var i = 0; i < rows.length; i++) {
      if (_stop) break;
      final String tpl;
      final int vNum;
      switch (_mode) {
        case _Mode.single:
          tpl = single!;
          vNum = _singleIndex + 1;
        case _Mode.random:
          final k = _rnd.nextInt(variants.length);
          tpl = variants[k];
          vNum = k + 1;
        case _Mode.rotate:
          final k = i % variants.length;
          tpl = variants[k];
          vNum = k + 1;
      }
      setState(() {
        rows[i].status = _St.sending;
        rows[i].variant = vNum;
      });
      final text = tpl.replaceAll('{name}', rows[i].name).replaceAll('{date}', rows[i].date);
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
            _variantsCard(dark),
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

  bool _canSend(int parsedCount) {
    if (parsedCount == 0) return false;
    if (_mode == _Mode.single) {
      return _singleIndex < _variants.length && _variants[_singleIndex].text.trim().isNotEmpty;
    }
    return _activeVariants().isNotEmpty;
  }

  Widget _modeChips() {
    const items = [(_Mode.rotate, 'По очереди'), (_Mode.random, 'Рандом'), (_Mode.single, 'Один')];
    return Wrap(
      spacing: 8,
      children: [
        for (final (m, label) in items)
          ChoiceChip(
            label: Text(label),
            selected: _mode == m,
            onSelected: _running ? null : (_) => setState(() => _mode = m),
            selectedColor: AppColors.brand.withValues(alpha: 0.18),
            labelStyle: TextStyle(
              fontWeight: _mode == m ? FontWeight.w700 : FontWeight.w500,
              color: _mode == m ? AppColors.brand : null,
            ),
          ),
      ],
    );
  }

  Widget _variantsCard(bool dark) {
    final sec = context.semantic.textSecondary;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1B242B) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(color: AppColors.brand.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.message_rounded, size: 16, color: AppColors.brand),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text('Тексты — ${_variants.length} вар.', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Пресет:', style: TextStyle(fontSize: 12.5, color: sec)),
          ActionChip(
            avatar: const Icon(Icons.notifications_active_outlined, size: 16, color: AppColors.brand),
            label: const Text('Напоминания'),
            onPressed: _running ? null : () => _loadPreset(_defaultVariants, single: false),
          ),
          ActionChip(
            avatar: const Icon(Icons.credit_card_rounded, size: 16, color: Color(0xFFC97A0A)),
            label: const Text('Предоплата'),
            onPressed: _running ? null : () => _loadPreset(const [_paymentTemplate], single: true),
          ),
        ]),
        const SizedBox(height: 10),
        Text('Переменные: {name}, {date}', style: TextStyle(fontSize: 12, color: sec)),
        const SizedBox(height: 10),
        _modeChips(),
        const SizedBox(height: 6),
        Text(
          switch (_mode) {
            _Mode.single => 'Всем уходит один выбранный вариант (отметьте его ниже).',
            _Mode.random => 'Каждому — случайный вариант из списка.',
            _Mode.rotate => 'Каждому — следующий вариант по кругу.',
          },
          style: TextStyle(fontSize: 12, color: sec),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < _variants.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (_mode == _Mode.single) ...[
                  GestureDetector(
                    onTap: _running ? null : () => setState(() => _singleIndex = i),
                    child: Icon(
                      _singleIndex == i ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 19,
                      color: _singleIndex == i ? AppColors.brand : Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.brand.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(7)),
                  child: Text('Вариант ${i + 1}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.brand)),
                ),
                const Spacer(),
                if (_variants.length > 1 && !_running)
                  GestureDetector(
                    onTap: () => _removeVariant(i),
                    child: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.shade300),
                  ),
              ]),
              const SizedBox(height: 6),
              _multiline(dark, _variants[i], minLines: 3, mono: false, enabled: !_running),
            ]),
          ),
        if (!_running)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addVariant,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Добавить вариант'),
              style: TextButton.styleFrom(foregroundColor: AppColors.brand),
            ),
          ),
      ]),
    );
  }

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
                  onPressed: _canSend(parsedCount) ? _start : null,
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
                if (_rows[i].variant > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: AppColors.brand.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(7)),
                    child: Text('в${_rows[i].variant}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.brand)),
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
