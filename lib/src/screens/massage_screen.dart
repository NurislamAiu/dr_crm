import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../models/massage.dart';
import '../state/providers.dart';
import 'archive_actions.dart';
import 'day_utils.dart';
import 'massage_sheet.dart';
import 'soft_ui.dart';

// Тёплый жёлтый фон раздела «Массаж».
const _pageBg = Color(0xFFFDF8EC);
const _mass = Color(0xFFE3A008);      // янтарный акцент
const _massDeep = Color(0xFF8C5F04);  // тёмный янтарь для текста

/// Экран массажа — «мягкий» стиль в жёлтой палитре: шапка со скруглением,
/// недельная лента, стат-карточки. Данные из Firestore `massages`.
class MassageScreen extends ConsumerStatefulWidget {
  const MassageScreen({super.key});

  @override
  ConsumerState<MassageScreen> createState() => _MassageScreenState();
}

class _MassageScreenState extends ConsumerState<MassageScreen> {
  bool _archive = false;
  DateTime? _filterDate;
  List<Massage> _current = [];
  Set<int> _daysWithData = {};

  static bool _sameDay(DateTime? a, DateTime? b) =>
      a != null && b != null && a.year == b.year && a.month == b.month && a.day == b.day;

  void _toggleDay(DateTime day) {
    setState(() => _filterDate = _sameDay(_filterDate, day) ? null : day);
  }

  Future<void> _pickFilterDate() async {
    final res = await showSoftDatePicker(context, selected: _filterDate, accent: _massDeep, daysWithData: _daysWithData);
    if (res == null) return;
    setState(() => _filterDate = res is DateTime ? res : null);
  }

  Future<void> _quickEditPrepayment(Massage l) async {
    final res = await showAmountDialog(
      context,
      initial: l.prepayment != null ? '${l.prepayment!.toInt()}' : '',
      currency: l.currency ?? defaultCurrency(l.phone),
      accent: _massDeep,
    );
    if (res == null) return;
    final amount = res.$1.isEmpty ? null : num.tryParse(res.$1.replaceAll(',', '.').replaceAll(' ', ''));
    try {
      await ref.read(massageRepositoryProvider).update(
            l.id!,
            Massage(massageNumber: l.massageNumber, name: l.name, phone: l.phone, appointmentDate: l.appointmentDate,
                appointmentTime: l.appointmentTime, prepayment: amount, currency: amount != null ? res.$2 : null),
          );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  void _export() {
    final leads = _current;
    if (leads.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Список пуст')));
      return;
    }
    // Формат-расписание: группировка по ДАТЕ ПРИЁМА, внутри дня — по времени,
    // нумерация каждый день заново с 1: «1-15:00 Ринат 79058962500(50 000)».
    final byDay = <DateTime?, List<Massage>>{};
    for (final l in leads) {
      final d = l.appointmentDate;
      final key = d != null ? DateTime(d.year, d.month, d.day) : null;
      byDay.putIfAbsent(key, () => []).add(l);
    }
    final days = byDay.keys.toList()
      ..sort((a, b) {
        if (a == null) return 1; // «без даты» — в конец
        if (b == null) return -1;
        return a.compareTo(b);
      });

    final b = StringBuffer();
    num totalKzt = 0, totalRub = 0;
    for (final day in days) {
      final list = byDay[day]!
        ..sort((a, b) => (a.appointmentTime ?? '').compareTo(b.appointmentTime ?? ''));
      final sumKzt = list.where((l) => (l.currency ?? kKzt) != kRub).fold<num>(0, (s, l) => s + (l.prepayment ?? 0));
      final sumRub = list.where((l) => l.currency == kRub).fold<num>(0, (s, l) => s + (l.prepayment ?? 0));
      totalKzt += sumKzt;
      totalRub += sumRub;
      b.writeln(day != null ? dateRu(day) : 'Без даты приёма');
      b.writeln();
      for (var i = 0; i < list.length; i++) {
        final l = list[i];
        final time = (l.appointmentTime ?? '').trim();
        final prep = l.prepayment != null ? '(${moneyWith(l.prepayment!, l.currency)})' : '';
        b.writeln('${i + 1}${time.isNotEmpty ? '-$time' : ''} ${l.name} ${l.phone ?? ''}$prep');
      }
      if (sumKzt > 0 || sumRub > 0) {
        b.writeln();
        b.writeln('Итого: ${[if (sumKzt > 0) '${money(sumKzt)} ₸', if (sumRub > 0) '${money(sumRub)} ₽'].join(' · ')}');
      }
      b.writeln();
    }
    final totals = [if (totalKzt > 0) '${money(totalKzt)} ₸', if (totalRub > 0) '${money(totalRub)} ₽'];
    b.writeln('Всего: ${leads.length} записей${totals.isEmpty ? '' : ' · предоплата ${totals.join(' · ')}'}');
    final text = b.toString();
    Clipboard.setData(ClipboardData(text: text));
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Экспорт (${leads.length})'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Закрыть')),
          FilledButton.icon(
            icon: const Icon(Iconsax.copy, size: 18),
            label: const Text('Копировать'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(d);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Скопировано')));
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Архив видит только админ.
    final role = ref.watch(appConfigProvider).role;
    final isAdmin = role == 'admin' || role == 'administrator';
    if (!isAdmin && _archive) _archive = false;
    // Кэшированный провайдер: одна подписка на всё приложение.
    final massagesAsync = ref.watch(massagesListProvider);
    return Scaffold(
      backgroundColor: _pageBg,
      body: Builder(
        builder: (context) {
          final all = massagesAsync.value ?? const <Massage>[];
          final active = all.where((l) => !l.archived).toList();
          // Группировка и фильтр — по ДАТЕ ПРИЁМА (кто когда придёт).
          final daysWithData = {for (final l in active) if (l.appointmentDate != null) WeekStrip.keyOf(l.appointmentDate!)};
          _daysWithData = daysWithData;

          var leads = all.where((l) => l.archived == _archive).toList();
          if (_filterDate != null) leads = leads.where((l) => _sameDay(l.appointmentDate, _filterDate)).toList();
          // Дни: ближайшие сверху; внутри дня — по времени приёма.
          leads.sort((a, b) {
            final da = a.appointmentDate, db = b.appointmentDate;
            if (da == null && db != null) return 1;   // без даты — в конец
            if (da != null && db == null) return -1;
            if (da != null && db != null) {
              final byDay = DateTime(db.year, db.month, db.day).compareTo(DateTime(da.year, da.month, da.day));
              if (byDay != 0) return byDay;
            }
            return (a.appointmentTime ?? '').compareTo(b.appointmentTime ?? '');
          });
          _current = leads;
          // Предоплата считается раздельно по валютам.
          final sumKzt = leads.where((l) => (l.currency ?? kKzt) != kRub).fold<num>(0, (s, l) => s + (l.prepayment ?? 0));
          final sumRub = leads.where((l) => l.currency == kRub).fold<num>(0, (s, l) => s + (l.prepayment ?? 0));
          final sumLabel = [if (sumKzt > 0) '${money(sumKzt)} ₸', if (sumRub > 0) '${money(sumRub)} ₽'];

          final headerDate = _filterDate ?? DateTime.now();

          return Column(
            children: [
              SoftHeader(
                color: _mass,
                colorDeep: _massDeep,
                title: _archive ? 'Архив массажа' : 'Массаж',
                dateLabel: weekdayDateRu(headerDate),
                actions: [
                  SoftHeaderButton(icon: Iconsax.export_1, accent: _massDeep, tooltip: 'Экспорт', onTap: _export),
                  if (isAdmin)
                    SoftHeaderButton(
                      icon: Iconsax.archive_1,
                      accent: _massDeep,
                      active: _archive,
                      tooltip: _archive ? 'К активным' : 'Архив',
                      onTap: () => setState(() => _archive = !_archive),
                    ),
                  SoftHeaderButton(
                    icon: _filterDate != null ? Iconsax.calendar_tick : Iconsax.calendar_1,
                    accent: _massDeep,
                    active: _filterDate != null,
                    tooltip: 'Выбрать дату',
                    onTap: _pickFilterDate,
                  ),
                  SoftHeaderButton(icon: Iconsax.add, filled: true, accent: _massDeep, tooltip: 'Новая запись', onTap: () => MassageSheet.show(context)),
                ],
                strip: WeekStrip(
                  selected: _filterDate,
                  daysWithData: daysWithData,
                  accent: _massDeep,
                  onTap: _toggleDay,
                ),
              ),
              Expanded(
                child: Container(
                  transform: Matrix4.translationValues(0, -22, 0),
                  decoration: const BoxDecoration(color: _pageBg, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
                  child: !massagesAsync.hasValue
                      ? const Center(child: CircularProgressIndicator())
                      : _sheet(leads, sumLabel.isEmpty ? '0 ₸' : sumLabel.join(' · ')),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sheet(List<Massage> leads, String sumLabel) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 20, 15, 4),
          child: Row(children: [
            StatCard(
              value: '${leads.length}',
              label: _filterDate != null ? 'записей за день' : 'записей',
              accent: kInk,
              icon: Iconsax.health,
              iconColor: _mass,
            ),
            const SizedBox(width: 10),
            StatCard(
              value: sumLabel,
              label: 'предоплата',
              accent: _massDeep,
              icon: Iconsax.empty_wallet,
              flex: 2,
            ),
          ]),
        ),
        if (_archive)
          const Padding(
            padding: EdgeInsets.fromLTRB(19, 14, 19, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Архив', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: kSub)),
            ),
          )
        else
          const SizedBox(height: 8),
        Expanded(child: _list(leads)),
      ],
    );
  }

  Widget _list(List<Massage> leads) {
    if (leads.isEmpty) {
      return _Empty(
        icon: _archive ? Iconsax.archive_1 : Iconsax.health,
        title: _archive ? 'Архив пуст' : (_filterDate != null ? 'Нет записей на эту дату' : 'Пока нет записей'),
        subtitle: _archive ? 'Сюда попадают удалённые записи' : 'Создайте запись кнопкой + или из чата',
      );
    }
    final repo = ref.read(massageRepositoryProvider);
    final grouped = _filterDate == null;
    final rows = grouped ? groupByDay<Massage>(leads, (l) => l.appointmentDate) : leads.cast<Object>().toList();

    // Нумерация: каждый день приёма заново с 1, по времени (как в расписании).
    final dayIdx = <String, int>{};
    final byDay = <String, List<Massage>>{};
    for (final l in leads) {
      byDay.putIfAbsent(dayLabel(l.appointmentDate), () => []).add(l);
    }
    for (final list in byDay.values) {
      final ordered = [...list]..sort((a, b) => (a.appointmentTime ?? '').compareTo(b.appointmentTime ?? ''));
      for (var i = 0; i < ordered.length; i++) {
        dayIdx[ordered[i].id ?? ''] = i + 1;
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(15, 2, 15, 24),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row is String) {
          final cnt = leads.where((l) => dayLabel(l.appointmentDate) == row).length;
          return softDayHeader(row, cnt, _massDeep);
        }
        final lead = row as Massage;
        final n = dayIdx[lead.id ?? ''];
        return ArchiveActions(
          itemKey: ValueKey(lead.id),
          archived: _archive,
          label: 'запись №${n ?? ''} ${lead.name}',
          onTap: _archive ? null : () => MassageSheet.show(context, existing: lead),
          onLongPress: () => copyPhone(context, lead.phone),
          onArchive: () => repo.archive(lead.id!, true),
          onRestore: () => repo.archive(lead.id!, false),
          onDeleteForever: () => repo.delete(lead.id!),
          child: _MassageCard(lead, displayNumber: n, onEditPrepayment: _archive ? null : () => _quickEditPrepayment(lead)),
        );
      },
    );
  }
}

class _MassageCard extends StatelessWidget {
  const _MassageCard(this.lead, {this.displayNumber, this.onEditPrepayment});
  final Massage lead;

  /// Порядковый номер внутри дня (1..n), без учёта архива.
  final int? displayNumber;
  final VoidCallback? onEditPrepayment;

  @override
  Widget build(BuildContext context) {
    final time = lead.appointmentTime;
    final paid = lead.prepayment != null;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(13, 13, 14, 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          CountryAvatar(phone: lead.phone, name: lead.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(lead.name.isEmpty ? 'Без имени' : lead.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: kInk, letterSpacing: -0.2)),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                      [
                        if (displayNumber != null) '№$displayNumber',
                        if (lead.phone?.isNotEmpty == true) formatPhone(lead.phone),
                      ].join(' · '),
                      maxLines: 1,
                      style: const TextStyle(fontSize: 12.5, color: kSub)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onEditPrepayment,
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (time != null && time.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFF0F4F3), borderRadius: BorderRadius.circular(9)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Iconsax.clock, size: 11, color: kSub),
                      const SizedBox(width: 4),
                      Text(time,
                          style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF465B55),
                              fontFeatures: [FontFeature.tabularFigures()])),
                    ]),
                  ),
                if (time != null && time.isNotEmpty) const SizedBox(height: 7),
                paid
                    ? Text(moneyWith(lead.prepayment!, lead.currency),
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: _massDeep,
                            letterSpacing: -0.2,
                            fontFeatures: [FontFeature.tabularFigures()]))
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: kAmber.withValues(alpha: 0.7)),
                        ),
                        child: const Text('+ оплата',
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: kAmberDeep)),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    // SingleChildScrollView: при маленькой высоте (клавиатура) не переполняется.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72, height: 72,
              decoration: BoxDecoration(color: _mass.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(22)),
              child: Icon(icon, size: 34, color: _massDeep),
            ),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 6),
            Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: kSub)),
          ],
        ),
      ),
    );
  }
}
