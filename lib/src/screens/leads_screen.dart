import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../design/design.dart';
import '../models/lead.dart';
import '../state/providers.dart';
import 'archive_actions.dart';
import 'lead_sheet.dart';
import 'soft_ui.dart';

// Тил-тонированный фон (медицинская палитра из дизайн-системы).
const _pageBg = Color(0xFFF2F2F7); // surface дизайн-системы

/// Экран лидов — «мягкий» стиль: тил-шапка со скруглением, недельная лента,
/// стат-карточки, карточки с аватаром по стране. Данные из Firestore `leads`.
class LeadsScreen extends ConsumerStatefulWidget {
  const LeadsScreen({super.key});

  @override
  ConsumerState<LeadsScreen> createState() => _LeadsScreenState();
}

/// Экран — расписание приёмов: группировка и лента недели по ДНЮ ПРИЁМА.
/// Раньше заголовки дней были «Сегодня», «Вчера» без пояснения, какой это
/// день — приёма или записи, и руководство читало «Вчера» как «вчера
/// записали». Теперь даты пишутся полностью, а «кто и когда записал» —
/// мелкой строкой на карточке. Режимов нет: один экран — один ответ.
class _LeadsScreenState extends ConsumerState<LeadsScreen> {
  bool _archive = false;

  /// По умолчанию открыт СЕГОДНЯШНИЙ день: экран отвечает на первый вопрос
  /// «кто сегодня придёт», а не показывает всю историю сразу.
  DateTime? _filterDate = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  List<Lead> _current = [];
  Set<int> _daysWithData = {};

  static bool _sameDay(DateTime? a, DateTime? b) =>
      a != null && b != null && a.year == b.year && a.month == b.month && a.day == b.day;

  DateTime? _dateOf(Lead l) => l.appointmentDate;

  void _toggleDay(DateTime day) {
    setState(() => _filterDate = _sameDay(_filterDate, day) ? null : day);
  }

  /// Полная подпись дня: «Сегодня · 6 сентября, вс». Относительное слово —
  /// только как дополнение к дате, никогда вместо неё.
  static String _dayTitle(DateTime? d) {
    if (d == null) return 'Без даты приёма';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = day.difference(today).inDays;
    final base = weekdayDateRu(day);
    return switch (diff) {
      0 => 'Сегодня · $base',
      1 => 'Завтра · $base',
      -1 => 'Вчера · $base',
      _ => base,
    };
  }

  Future<void> _pickFilterDate() async {
    final res = await showSoftDatePicker(context, selected: _filterDate, accent: kTealDeep, daysWithData: _daysWithData);
    if (res == null) return;
    setState(() => _filterDate = res is DateTime ? res : null);
  }

  Future<void> _quickEditPrepayment(Lead l) async {
    final res = await showAmountDialog(
      context,
      initial: l.prepayment != null ? '${l.prepayment!.toInt()}' : '',
      currency: l.currency ?? defaultCurrency(l.phone),
      accent: kTealDeep,
    );
    if (res == null) return;
    final amount = res.$1.isEmpty ? null : num.tryParse(res.$1.replaceAll(',', '.').replaceAll(' ', ''));
    try {
      await ref.read(leadRepositoryProvider).update(
            l.id!,
            Lead(leadNumber: l.leadNumber, name: l.name, phone: l.phone, appointmentDate: l.appointmentDate,
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
    final byDay = <DateTime?, List<Lead>>{};
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
    b.writeln('Всего: ${leads.length} лидов${totals.isEmpty ? '' : ' · предоплата ${totals.join(' · ')}'}');
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
    // Кэшированный провайдер: одна подписка на всё приложение —
    // setState (фильтры/архив) больше не перечитывает коллекцию с сервера.
    final leadsAsync = ref.watch(leadsListProvider);
    // Кто завёл лид — по uid из users/. На карточке это отвечает на второй
    // вопрос руководства: «а кто его записал».
    final managers = ref.watch(managersProvider).value ?? const <Map<String, dynamic>>[];
    String author(String? uid) {
      if (uid == null || uid.isEmpty) return '';
      for (final m in managers) {
        if (m['id'] == uid) return ((m['name'] as String?) ?? '').trim().split(' ').first;
      }
      return '';
    }

    return Scaffold(
      backgroundColor: _pageBg,
      body: Builder(
        builder: (context) {
          final all = leadsAsync.value ?? const <Lead>[];
          final active = all.where((l) => !l.archived).toList();
          // Числа под днями ленты — в текущем режиме: сколько приёмов (или
          // сколько записано) в каждый день недели.
          final counts = <int, int>{};
          for (final l in active) {
            final d = _dateOf(l);
            if (d != null) counts[WeekStrip.keyOf(d)] = (counts[WeekStrip.keyOf(d)] ?? 0) + 1;
          }
          _daysWithData = counts.keys.toSet();

          var leads = all.where((l) => l.archived == _archive).toList();
          if (_filterDate != null) leads = leads.where((l) => _sameDay(_dateOf(l), _filterDate)).toList();
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          {
            // Расписание: сначала сегодня и ближайшие дни по порядку, прошедшие
            // — в конец (от вчера к более старым); без даты — самые последние.
            // Внутри дня — по времени приёма.
            leads.sort((a, b) {
              final da = a.appointmentDate, db = b.appointmentDate;
              if (da == null && db != null) return 1;
              if (da != null && db == null) return -1;
              if (da != null && db != null) {
                final xa = DateTime(da.year, da.month, da.day), xb = DateTime(db.year, db.month, db.day);
                final fa = !xa.isBefore(today), fb = !xb.isBefore(today);
                if (fa != fb) return fa ? -1 : 1;
                final byDay = fa ? xa.compareTo(xb) : xb.compareTo(xa);
                if (byDay != 0) return byDay;
              }
              return (a.appointmentTime ?? '').compareTo(b.appointmentTime ?? '');
            });
          }
          _current = leads;
          // Предоплата считается раздельно по валютам.
          final sumKzt = leads.where((l) => (l.currency ?? kKzt) != kRub).fold<num>(0, (s, l) => s + (l.prepayment ?? 0));
          final sumRub = leads.where((l) => l.currency == kRub).fold<num>(0, (s, l) => s + (l.prepayment ?? 0));
          final sumLabel = [if (sumKzt > 0) '${money(sumKzt)} ₸', if (sumRub > 0) '${money(sumRub)} ₽'];

          final headerDate = _filterDate ?? now;

          return Column(
            children: [
              SoftHeader(
                color: kTeal,
                colorDeep: kTealDeep,
                title: _archive ? 'Архив лидов' : 'Лиды',
                dateLabel: weekdayDateRu(headerDate),
                actions: [
                  SoftHeaderButton(icon: Iconsax.export_1, tooltip: 'Экспорт', onTap: _export),
                  if (isAdmin)
                    SoftHeaderButton(
                      icon: Iconsax.archive_1,
                      active: _archive,
                      tooltip: _archive ? 'К активным' : 'Архив',
                      onTap: () => setState(() => _archive = !_archive),
                    ),
                  SoftHeaderButton(
                    icon: _filterDate != null ? Iconsax.calendar_tick : Iconsax.calendar_1,
                    active: _filterDate != null,
                    tooltip: 'Выбрать дату',
                    onTap: _pickFilterDate,
                  ),
                  SoftHeaderButton(icon: Iconsax.add, filled: true, tooltip: 'Новый лид', onTap: () => LeadSheet.show(context)),
                ],
                strip: Column(
                  children: [
                    // Лента листается пальцем: две недели назад и полтора
                    // месяца вперёд — столько живёт расписание записей.
                    WeekStrip(
                      selected: _filterDate,
                      daysWithData: _daysWithData,
                      counts: counts,
                      accent: kTealDeep,
                      onTap: _toggleDay,
                      daysBack: 14,
                      daysAhead: 45,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  transform: Matrix4.translationValues(0, -22, 0),
                  decoration: const BoxDecoration(color: _pageBg, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
                  child: !leadsAsync.hasValue
                      ? const SkeletonList()
                      : _sheet(leads, sumLabel.isEmpty ? '0 ₸' : sumLabel.join(' · '), author),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sheet(List<Lead> leads, String sumLabel, String Function(String?) author) {
    // Явный заголовок над списком: какой день приёма показан.
    final String sectionTitle;
    if (_archive) {
      sectionTitle = 'Архив';
    } else if (_filterDate != null) {
      sectionTitle = 'Приёмы: ${_dayTitle(_filterDate)}';
    } else {
      sectionTitle = 'Все дни';
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 20, 15, 4),
          child: Row(children: [
            StatCard(
              value: '${leads.length}',
              label: _filterDate != null ? 'приёмов в этот день' : 'приёмов всего',
              accent: kInk,
              icon: Iconsax.calendar_1,
              iconColor: kTeal,
            ),
            const SizedBox(width: 10),
            StatCard(
              value: sumLabel,
              label: 'предоплата',
              accent: kTealDeep,
              icon: Iconsax.empty_wallet,
              flex: 2,
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(19, 14, 19, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  sectionTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: kTealDeep),
                ),
              ),
              if (_filterDate != null && !_archive)
                GestureDetector(
                  onTap: () => setState(() => _filterDate = null),
                  behavior: HitTestBehavior.opaque,
                  child: const Text(
                    'все дни',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: kSub),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _list(leads, author)),
      ],
    );
  }

  Widget _list(List<Lead> leads, String Function(String?) author) {
    if (leads.isEmpty) {
      return _Empty(
        icon: _archive ? Iconsax.archive_1 : Iconsax.calendar_1,
        title: _archive
            ? 'Архив пуст'
            : _filterDate != null
                ? 'На этот день приёмов нет'
                : 'Пока нет лидов',
        subtitle: _archive
            ? 'Сюда попадают удалённые лиды'
            : _filterDate != null
                ? 'Выберите другой день в ленте сверху'
                : 'Создайте лид кнопкой + или из чата',
      );
    }
    final repo = ref.read(leadRepositoryProvider);
    // Подпись дня считается ОДИН раз на день, а не на каждую карточку:
    // форматирование даты на 700 лидах в каждом кадре прокрутки — это и
    // были «лаги» экрана.
    final titleCache = <int, String>{};
    String titleOf(DateTime? d) {
      final k = d == null ? -1 : WeekStrip.keyOf(d);
      return titleCache.putIfAbsent(k, () => _dayTitle(d));
    }

    // Без фильтра — группы по дням с полной датой в заголовке; число лидов
    // в заголовке — из готовой карты, а не перебором списка на каждый заголовок.
    final grouped = _filterDate == null;
    final rows = <Object>[];
    final headerCount = <String, int>{};
    if (grouped) {
      String? current;
      for (final l in leads) {
        final key = titleOf(_dateOf(l));
        headerCount[key] = (headerCount[key] ?? 0) + 1;
        if (key != current) {
          current = key;
          rows.add(key);
        }
        rows.add(l);
      }
    } else {
      rows.addAll(leads);
    }

    // Нумерация в расписании: каждый день приёма заново с 1, по времени.
    final dayIdx = <String, int>{};
    final byDay = <int, List<Lead>>{};
    for (final l in leads) {
      final d = l.appointmentDate;
      byDay.putIfAbsent(d == null ? -1 : WeekStrip.keyOf(d), () => []).add(l);
    }
    for (final list in byDay.values) {
      final ordered = [...list]..sort((a, b) => (a.appointmentTime ?? '').compareTo(b.appointmentTime ?? ''));
      for (var i = 0; i < ordered.length; i++) {
        dayIdx[ordered[i].id ?? ''] = i + 1;
      }
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(15, 2, 15, 24 + MediaQuery.paddingOf(context).bottom),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row is String) {
          return softDayHeader(row, headerCount[row] ?? 0, kTealDeep);
        }
        final lead = row as Lead;
        final n = dayIdx[lead.id ?? ''];
        return ArchiveActions(
          itemKey: ValueKey(lead.id),
          archived: _archive,
          label: 'лид №${n ?? ''} ${lead.name}',
          onTap: _archive ? null : () => LeadSheet.show(context, existing: lead),
          onLongPress: () => copyPhone(context, lead.phone),
          onArchive: () => repo.archive(lead.id!, true),
          onRestore: () => repo.archive(lead.id!, false),
          onDeleteForever: () => repo.delete(lead.id!),
          child: _LeadCard(
            lead,
            displayNumber: n,
            author: author(lead.createdBy),
            onEditPrepayment: _archive ? null : () => _quickEditPrepayment(lead),
          ),
        );
      },
    );
  }
}

class _LeadCard extends StatelessWidget {
  const _LeadCard(
    this.lead, {
    this.displayNumber,
    this.onEditPrepayment,
    this.author = '',
  });
  final Lead lead;

  /// Порядковый номер внутри дня приёма (1..n), без учёта архива.
  final int? displayNumber;
  final VoidCallback? onEditPrepayment;

  /// Кто завёл лид (имя менеджера).
  final String author;

  static final bool _cheapPaint = Platform.isAndroid;

  @override
  Widget build(BuildContext context) {
    final time = lead.appointmentTime;
    final paid = lead.prepayment != null;
    // Третья строка: когда и кем записан — то, чего нет в группировке по дню
    // приёма. Мелко, без переключателей.
    final third = [
      if (lead.createdAt != null) 'записан ${dateRu(lead.createdAt!)}',
      if (author.isNotEmpty) author,
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(13, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        // На Android размытая тень под каждой карточкой — самая дорогая часть
        // кадра (список дёргался при прокрутке); там вместо неё тонкая рамка.
        border: _cheapPaint ? Border.all(color: const Color(0xFFE6E9EC)) : null,
        boxShadow: _cheapPaint
            ? null
            : [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
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
                const SizedBox(height: 3),
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
                if (third.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(third,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: kSub.withValues(alpha: 0.85))),
                ],
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
                if (time != null && time.isNotEmpty) ...[
                  _chip(Iconsax.clock, time),
                  const SizedBox(height: 7),
                ],
                paid
                    ? Text(moneyWith(lead.prepayment!, lead.currency),
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: kTealDeep,
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

  static Widget _chip(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFFF0F4F3), borderRadius: BorderRadius.circular(9)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 11, color: kSub),
          const SizedBox(width: 4),
          Text(text,
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF465B55),
                  fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      );
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
              decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(22)),
              child: Icon(icon, size: 34, color: kTeal),
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
