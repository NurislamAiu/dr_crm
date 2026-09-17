import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../data/waba_service.dart';
import '../models/lead.dart';
import '../models/massage.dart';
import '../state/providers.dart';
import 'soft_ui.dart';

const _pageBg = Color(0xFFF2F2F7);

/// Рассылка одобренного шаблона WABA.
///
/// Написать первым тому, кто не писал последние 24 часа, WhatsApp разрешает
/// ТОЛЬКО шаблоном, одобренным Meta. Свой текст здесь придумать нельзя — можно
/// выбрать готовый шаблон и подставить в него значения переменных.
///
/// Отправка идёт очередью с паузами: пачка одинаковых сообщений подряд роняет
/// качество номера. Каждое сообщение видно в переписке с пометкой «рассылка».
class WabaBroadcastScreen extends ConsumerStatefulWidget {
  const WabaBroadcastScreen({super.key});

  @override
  ConsumerState<WabaBroadcastScreen> createState() => _WabaBroadcastScreenState();
}

/// Что подставляем в переменную шаблона.
enum _VarSource { name, time, date, custom }

/// Получатель рассылки. dateText — дата словами («17 августа») для списка,
/// набранного руками: там календарной даты нет, только то, что написали.
typedef _Rcpt = ({String phone, String name, String time, DateTime? date, String dateText});

class _WabaBroadcastScreenState extends ConsumerState<WabaBroadcastScreen> {
  final _manual = TextEditingController();

  Future<List<WabaTemplate>>? _templates;
  WabaTemplate? _picked;

  /// Источник получателей: записи на дату или список номеров руками.
  bool _fromAppointments = true;
  DateTime _day = DateTime.now().add(const Duration(days: 1));

  /// Выбранные записи (ключ — номер телефона).
  final Set<String> _checked = {};

  /// Чем заполнять {{1}}, {{2}}… и текст для «своего значения».
  final List<_VarSource> _sources = [];
  final List<TextEditingController> _custom = [];

  int _gapSec = 20;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _templates = ref.read(wabaServiceProvider).templates();
  }

  @override
  void dispose() {
    _manual.dispose();
    for (final c in _custom) {
      c.dispose();
    }
    super.dispose();
  }

  void _pick(WabaTemplate t) {
    setState(() {
      _picked = t;
      // Первая переменная почти всегда имя, вторая — время записи.
      _sources
        ..clear()
        ..addAll(List.generate(t.vars, (i) => i == 0 ? _VarSource.name : (i == 1 ? _VarSource.time : _VarSource.custom)));
      for (final c in _custom) {
        c.dispose();
      }
      _custom
        ..clear()
        ..addAll(List.generate(t.vars, (_) => TextEditingController()));
    });
  }

  static String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');
  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// Номер в международном виде: WhatsApp знает только его. «8 775 …» —
  /// внутренний формат, кода страны 8 не существует; десять цифр без кода —
  /// казахстанский мобильный, ему не хватает семёрки.
  static String _phone(String raw) {
    final d = _digits(raw);
    if (d.length == 11 && d.startsWith('8')) return '7${d.substring(1)}';
    if (d.length == 10) return '7$d';
    return d;
  }

  /// Получатели из записей на выбранный день: лиды + массаж.
  List<_Rcpt> _appointments() {
    final leads = ref.watch(leadsListProvider).value ?? const <Lead>[];
    final mass = ref.watch(massagesListProvider).value ?? const <Massage>[];
    final out = <_Rcpt>[];
    final seen = <String>{};
    void add(String? phone, String name, String? time, DateTime? date, bool archived) {
      final p = _phone(phone ?? '');
      if (archived || p.length < 10 || seen.contains(p)) return;
      if (date == null || !_sameDay(date, _day)) return;
      seen.add(p);
      out.add((phone: p, name: name, time: (time ?? '').trim(), date: date, dateText: ''));
    }

    for (final l in leads) {
      add(l.phone, l.name, l.appointmentTime, l.appointmentDate, l.archived);
    }
    for (final m in mass) {
      add(m.phone, m.name, m.appointmentTime, m.appointmentDate, m.archived);
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  /// Получатели, набранные руками: «номер, имя, время, дата» построчно.
  /// Дата — необязательная четвёртая колонка словами: «17 августа».
  List<_Rcpt> _manualList() {
    final out = <_Rcpt>[];
    final seen = <String>{};
    for (final raw in _manual.text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      // Запятая внутри значения («Майра, Алимхан и Багдат») ломала бы разбор,
      // поэтому строку с «|» делим только по нему.
      final parts = line.contains('|') ? line.split('|') : line.split(RegExp(r'[,;\t]'));
      final phone = _phone(parts.first);
      if (phone.length < 10 || seen.contains(phone)) continue;
      seen.add(phone);
      out.add((
        phone: phone,
        name: parts.length > 1 ? parts[1].trim() : '',
        time: parts.length > 2 ? parts[2].trim() : '',
        date: null,
        dateText: parts.length > 3 ? parts[3].trim() : '',
      ));
    }
    return out;
  }

  List<_Rcpt> _recipients() {
    if (!_fromAppointments) return _manualList();
    return _appointments().where((a) => _checked.contains(a.phone)).toList();
  }

  List<String> _valuesFor(_Rcpt r) {
    return List.generate(_sources.length, (i) {
      final v = switch (_sources[i]) {
        _VarSource.name => r.name.trim().isEmpty ? 'клиент' : r.name.trim(),
        _VarSource.time => r.time,
        // Записи дают календарную дату, список руками — четвёртую колонку.
        _VarSource.date => r.date != null ? dateRu(r.date!) : r.dateText,
        _VarSource.custom => _custom[i].text.trim(),
      };
      // Пустое значение WhatsApp вставит как дырку («записаны на .»), поэтому
      // подставляем прочерк — а в предпросмотре предупреждаем.
      return v.isEmpty ? '—' : v;
    });
  }

  String _render(String body, List<String> values) =>
      body.replaceAllMapped(RegExp(r'\{\{(\d+)\}\}'), (m) {
        final i = int.tryParse(m.group(1) ?? '') ?? 0;
        return (i >= 1 && i <= values.length) ? values[i - 1] : '';
      });

  Future<void> _send() async {
    final t = _picked;
    final list = _recipients();
    if (t == null || list.isEmpty) return;

    final minutes = ((list.length * _gapSec) / 60).ceil();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Отправить рассылку?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Шаблон «${t.title}» уйдёт ${list.length} получателям.'),
          const SizedBox(height: 8),
          Text('Пауза между отправками $_gapSec сек — всё займёт около $minutes мин.',
              style: const TextStyle(fontSize: 13, color: kSub)),
          const SizedBox(height: 8),
          const Text(
            'Каждый получатель займёт слот из суточного лимита переписок, '
            'начатых компанией (250 в бизнес-аккаунте).',
            style: TextStyle(fontSize: 13, color: kSub),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kTeal),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Отправить'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _sending = true);
    try {
      final res = await ref.read(wabaServiceProvider).sendTemplate(
            templateId: t.id,
            body: t.body,
            gapSec: _gapSec,
            recipients: [
              for (final r in list) (phone: r.phone, name: r.name, values: _valuesFor(r)),
            ],
          );
      if (!mounted) return;
      setState(() => _checked.clear());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Принято ${res.queued}, уйдёт примерно за ${res.minutes} мин')),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _recipients();
    return Scaffold(
      backgroundColor: _pageBg,
      body: Column(children: [
        SoftHeader(
          color: kTeal,
          colorDeep: kTealDeep,
          title: 'Рассылка',
          dateLabel: 'Шаблоны WhatsApp Business',
          showBack: true,
          actions: const [],
        ),
        Expanded(
          child: Container(
            transform: Matrix4.translationValues(0, -22, 0),
            decoration: const BoxDecoration(
              color: _pageBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(15, 22, 15, 28),
              children: [
                _section('1. Шаблон', 'Свой текст WhatsApp не пропустит — только одобренный Meta'),
                _templatesCard(),
                if (_picked != null) ...[
                  const SizedBox(height: 18),
                  _section('2. Кому', 'Записи на день или свой список номеров'),
                  _recipientsCard(),
                  if (_picked!.vars > 0) ...[
                    const SizedBox(height: 18),
                    _section('3. Что подставить', 'Значения переменных шаблона'),
                    _varsCard(),
                  ],
                  const SizedBox(height: 18),
                  _section('Предпросмотр', 'Так увидит первый получатель'),
                  _previewCard(list),
                ],
              ],
            ),
          ),
        ),
        if (_picked != null) _sendBar(list.length),
      ]),
    );
  }

  Widget _section(String title, String hint) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: kInk)),
          const SizedBox(height: 2),
          Text(hint, style: const TextStyle(fontSize: 12.5, color: kSub)),
        ]),
      );

  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(14)}) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
        ),
        // CheckboxListTile красит подсветку и рябь поверх ближайшего Material —
        // без него, прямо внутри закрашенного Container, эффекты были бы
        // невидимы (предупреждение Flutter «background color or ink splashes
        // may be invisible»). Прозрачный Material ничего не меняет визуально.
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: padding, child: child),
        ),
      );

  Widget _templatesCard() {
    return FutureBuilder<List<WabaTemplate>>(
      future: _templates,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _card(child: const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())));
        }
        if (snap.hasError) {
          return _card(child: Text('Не удалось получить шаблоны: ${snap.error}', style: const TextStyle(fontSize: 13, color: kSub)));
        }
        final all = (snap.data ?? const <WabaTemplate>[]).where((t) => t.isApproved).toList();
        if (all.isEmpty) {
          return _card(
            child: const Text(
              'Одобренных шаблонов нет. Их создают в кабинете Wazzup, дальше Meta проверяет текст.',
              style: TextStyle(fontSize: 13, color: kSub),
            ),
          );
        }
        return Column(
          children: [
            for (final t in all)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _card(
                  padding: EdgeInsets.zero,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () => _pick(t),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(
                          _picked?.id == t.id ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                          color: _picked?.id == t.id ? kTeal : Colors.black26,
                          size: 22,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Flexible(
                                child: Text(t.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
                              ),
                              const SizedBox(width: 8),
                              if (t.vars > 0)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8)),
                                  child: Text('${t.vars} поля',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: kTealDeep)),
                                ),
                            ]),
                            const SizedBox(height: 4),
                            Text(t.body,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5, color: kSub, height: 1.3)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _recipientsCard() {
    final appts = _fromAppointments ? _appointments() : const <_Rcpt>[];
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: _tab('Записи на день', _fromAppointments, () => setState(() => _fromAppointments = true))),
          const SizedBox(width: 8),
          Expanded(child: _tab('Свой список', !_fromAppointments, () => setState(() => _fromAppointments = false))),
        ]),
        const SizedBox(height: 14),
        if (_fromAppointments) ...[
          Row(children: [
            Expanded(
              child: Text(weekdayDateRu(_day),
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: kInk)),
            ),
            TextButton.icon(
              icon: const Icon(Iconsax.calendar_1, size: 18),
              label: const Text('Дата'),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _day,
                  firstDate: DateTime.now().subtract(const Duration(days: 30)),
                  lastDate: DateTime.now().add(const Duration(days: 180)),
                );
                if (picked != null) setState(() => _day = picked);
              },
            ),
          ]),
          if (appts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('На этот день записей нет', style: TextStyle(fontSize: 13, color: kSub)),
            )
          else ...[
            Row(children: [
              Text('${_checked.length} из ${appts.length}', style: const TextStyle(fontSize: 13, color: kSub)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  final all = appts.map((a) => a.phone).toSet();
                  if (_checked.containsAll(all)) {
                    _checked.removeAll(all);
                  } else {
                    _checked.addAll(all);
                  }
                }),
                child: Text(_checked.containsAll(appts.map((a) => a.phone).toSet()) ? 'Снять все' : 'Выбрать всех'),
              ),
            ]),
            for (final a in appts)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _checked.contains(a.phone),
                onChanged: (v) => setState(() => v == true ? _checked.add(a.phone) : _checked.remove(a.phone)),
                title: Text(a.name.isEmpty ? '+${a.phone}' : a.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                subtitle: Text('+${a.phone}${a.time.isEmpty ? '' : ' · ${a.time}'}',
                    style: const TextStyle(fontSize: 12.5, color: kSub)),
              ),
          ],
        ] else
          TextField(
            controller: _manual,
            minLines: 4,
            maxLines: 12,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: '+7 701 123-45-67, Айгерим, 12:00, 17 августа\n+7 747 000-00-00, Данияр, 15:30, 17 августа',
              hintStyle: TextStyle(fontSize: 13.5, color: kSub),
              helperText: 'По одному в строке через запятую: номер, имя, время, дата',
              helperStyle: TextStyle(fontSize: 12, color: kSub),
              border: OutlineInputBorder(),
            ),
          ),
      ]),
    );
  }

  Widget _tab(String label, bool active, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? kTeal.withValues(alpha: 0.12) : const Color(0xFFF2F5F7),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700, color: active ? kTealDeep : kSub)),
        ),
      );

  Widget _varsCard() {
    return _card(
      child: Column(children: [
        for (var i = 0; i < _sources.length; i++) ...[
          if (i > 0) const Divider(height: 20),
          Row(children: [
            Container(
              width: 34, height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(11)),
              child: Text('{{${i + 1}}}', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: kTealDeep)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<_VarSource>(
                  isExpanded: true,
                  value: _sources[i],
                  items: const [
                    DropdownMenuItem(value: _VarSource.name, child: Text('Имя клиента')),
                    DropdownMenuItem(value: _VarSource.time, child: Text('Время записи')),
                    DropdownMenuItem(value: _VarSource.date, child: Text('Дата записи')),
                    DropdownMenuItem(value: _VarSource.custom, child: Text('Свой текст')),
                  ],
                  onChanged: (v) => setState(() => _sources[i] = v ?? _VarSource.custom),
                ),
              ),
            ),
          ]),
          if (_sources[i] == _VarSource.custom)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextField(
                controller: _custom[i],
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'Значение', isDense: true, border: OutlineInputBorder()),
              ),
            ),
        ],
      ]),
    );
  }

  Widget _previewCard(List<_Rcpt> list) {
    final t = _picked!;
    final sample = list.isEmpty
        ? _render(t.body, List.filled(t.vars, '…'))
        : _render(t.body, _valuesFor(list.first));
    // У кого не хватает данных (нет времени записи и т.п.) — уйдёт прочерк.
    final incomplete = list.where((r) => _valuesFor(r).contains('—')).length;
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFE7FFDB), borderRadius: BorderRadius.circular(14)),
          child: Text(sample, style: const TextStyle(fontSize: 14, height: 1.35, color: kInk)),
        ),
        if (incomplete > 0) ...[
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Iconsax.info_circle, size: 16, color: kAmberDeep),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'У $incomplete получателей не заполнено значение — вместо него уйдёт «—». '
                'Для списка вручную формат строки: номер, имя, время.',
                style: const TextStyle(fontSize: 12.5, color: kAmberDeep, height: 1.3),
              ),
            ),
          ]),
        ],
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Iconsax.timer_1, size: 17, color: kSub),
          const SizedBox(width: 8),
          const Text('Пауза между отправками', style: TextStyle(fontSize: 13.5, color: kInk)),
          const Spacer(),
          DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _gapSec,
              items: const [
                DropdownMenuItem(value: 10, child: Text('10 сек')),
                DropdownMenuItem(value: 20, child: Text('20 сек')),
                DropdownMenuItem(value: 40, child: Text('40 сек')),
                DropdownMenuItem(value: 60, child: Text('1 мин')),
              ],
              onChanged: (v) => setState(() => _gapSec = v ?? 20),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _sendBar(int count) {
    final minutes = ((count * _gapSec) / 60).ceil();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 6, 15, 12),
        child: SizedBox(
          height: 54,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: kTeal,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            ),
            icon: _sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Iconsax.send_1, size: 20),
            label: Text(
              count == 0 ? 'Выберите получателей' : 'Отправить $count · ~$minutes мин',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            onPressed: count == 0 || _sending ? null : _send,
          ),
        ),
      ),
    );
  }
}
