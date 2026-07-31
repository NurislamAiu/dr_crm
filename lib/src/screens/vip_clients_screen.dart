import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../models/vip_client.dart';
import '../state/providers.dart';
import 'archive_actions.dart';
import 'day_utils.dart';
import 'soft_ui.dart';
import 'vip_client_sheet.dart';

const _pageBg = Color(0xFFF7F6F7);
const _vipRed = Color(0xFFE23744);
const _vipRedDark = Color(0xFFB81F2D);

/// Экран VIP-клиентов — «мягкий» стиль: шапка со скруглением, недельная лента,
/// стат-карточки, карточки с аватаром по стране и чипом статуса.
class VipClientsScreen extends ConsumerStatefulWidget {
  const VipClientsScreen({super.key});

  @override
  ConsumerState<VipClientsScreen> createState() => _VipClientsScreenState();
}

/// Ключевая дата VIP: прилёт, иначе приём у врача.
DateTime? vipDate(VipClient c) => c.arrivalDate ?? c.doctorAppointmentDate;

class _VipClientsScreenState extends ConsumerState<VipClientsScreen> {
  bool _archive = false;
  DateTime? _filterDate;
  List<VipClient> _current = [];
  Set<int> _daysWithData = {};

  static bool _sameDay(DateTime? a, DateTime? b) =>
      a != null && b != null && a.year == b.year && a.month == b.month && a.day == b.day;

  void _toggleDay(DateTime day) => setState(() => _filterDate = _sameDay(_filterDate, day) ? null : day);

  Future<void> _pickFilterDate() async {
    final res = await showSoftDatePicker(context, selected: _filterDate, accent: _vipRedDark, daysWithData: _daysWithData);
    if (res == null) return;
    setState(() => _filterDate = res is DateTime ? res : null);
  }

  Future<void> _quickEditStatus(VipClient c) async {
    final s = await showModalBottomSheet<VipStatus>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Align(alignment: Alignment.centerLeft, child: Text('Статус клиента', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          ),
          const Divider(height: 1),
          for (final st in VipStatus.values)
            ListTile(
              leading: Icon(st == c.status ? Iconsax.tick_circle : Iconsax.record_circle, color: st == c.status ? statusColor(st) : Colors.grey),
              title: Text(st.label),
              onTap: () => Navigator.pop(sheet, st),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (s == null || s == c.status) return;
    try {
      await ref.read(vipRepositoryProvider).setStatus(c.id!, s);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  void _export() {
    final items = _current;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Список пуст')));
      return;
    }
    // Разбивка по дням: заголовок дня + строки с нумерацией внутри дня.
    final groups = <String, List<VipClient>>{};
    for (final c in items) {
      groups.putIfAbsent(dayLabel(vipDate(c)), () => []).add(c);
    }
    final b = StringBuffer();
    groups.forEach((day, list) {
      // Внутри дня — хронологически, нумерация каждый день заново с 1.
      final ordered = [...list]..sort((a, b) => (a.arrivalTime ?? '').compareTo(b.arrivalTime ?? ''));
      b.writeln('$day — ${list.length}');
      b.writeln('№\tТелефон\tИмя\tСтатус');
      for (var i = 0; i < ordered.length; i++) {
        final c = ordered[i];
        b.writeln('${i + 1}\t${c.phone ?? ''}\t${c.name}\t${c.status.label}');
      }
      b.writeln();
    });
    b.writeln('Всего: ${items.length} VIP');
    final text = b.toString();
    Clipboard.setData(ClipboardData(text: text));
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Экспорт (${items.length})'),
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
    final vipsAsync = ref.watch(vipClientsListProvider);
    return Scaffold(
      backgroundColor: _pageBg,
      body: Builder(
        builder: (context) {
          final all = vipsAsync.value ?? const <VipClient>[];
          final active = all.where((c) => !c.archived).toList();
          // Группировка и фильтр — по дате ПРИЛЁТА (когда клиент приезжает).
          final daysWithData = {for (final c in active) if (vipDate(c) != null) WeekStrip.keyOf(vipDate(c)!)};
          _daysWithData = daysWithData;

          var clients = all.where((c) => c.archived == _archive).toList();
          if (_filterDate != null) clients = clients.where((c) => _sameDay(vipDate(c), _filterDate)).toList();
          // Дни: ближайшие сверху; внутри дня — по времени прилёта.
          clients.sort((a, b) {
            final da = vipDate(a), db = vipDate(b);
            if (da == null && db != null) return 1;   // без даты — в конец
            if (da != null && db == null) return -1;
            if (da != null && db != null) {
              final byDay = DateTime(db.year, db.month, db.day).compareTo(DateTime(da.year, da.month, da.day));
              if (byDay != 0) return byDay;
            }
            return (a.arrivalTime ?? '').compareTo(b.arrivalTime ?? '');
          });
          _current = clients;
          final inWork = clients.where((c) => c.status != VipStatus.departed && c.status != VipStatus.completed).length;
          final headerDate = _filterDate ?? DateTime.now();

          return Column(
            children: [
              SoftHeader(
                color: _vipRed,
                colorDeep: _vipRedDark,
                title: _archive ? 'Архив VIP' : 'VIP-клиенты',
                dateLabel: weekdayDateRu(headerDate),
                actions: [
                  SoftHeaderButton(icon: Iconsax.export_1, accent: _vipRedDark, tooltip: 'Экспорт', onTap: _export),
                  if (isAdmin)
                    SoftHeaderButton(
                      icon: Iconsax.archive_1,
                      accent: _vipRedDark,
                      active: _archive,
                      tooltip: _archive ? 'К активным' : 'Архив',
                      onTap: () => setState(() => _archive = !_archive),
                    ),
                  SoftHeaderButton(
                    icon: _filterDate != null ? Iconsax.calendar_tick : Iconsax.calendar_1,
                    accent: _vipRedDark,
                    active: _filterDate != null,
                    tooltip: 'Выбрать дату',
                    onTap: _pickFilterDate,
                  ),
                  SoftHeaderButton(icon: Iconsax.add, filled: true, accent: _vipRedDark, tooltip: 'Новый VIP', onTap: () => VipClientSheet.show(context)),
                ],
                strip: WeekStrip(selected: _filterDate, daysWithData: daysWithData, accent: _vipRedDark, onTap: _toggleDay),
              ),
              Expanded(
                child: Container(
                  transform: Matrix4.translationValues(0, -22, 0),
                  decoration: const BoxDecoration(color: _pageBg, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
                  child: !vipsAsync.hasValue ? const Center(child: CircularProgressIndicator()) : _sheet(clients, inWork),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sheet(List<VipClient> clients, int inWork) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 20, 15, 4),
          child: Row(children: [
            StatCard(
              value: '${clients.length}',
              label: _filterDate != null ? 'VIP за день' : 'всего VIP',
              accent: kInk,
              icon: Iconsax.crown_1,
              iconColor: _vipRed,
            ),
            const SizedBox(width: 10),
            StatCard(
              value: '$inWork',
              label: 'в работе',
              accent: _vipRedDark,
              icon: Iconsax.health,
              iconColor: _vipRedDark,
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
        Expanded(child: _list(clients)),
      ],
    );
  }

  Widget _list(List<VipClient> clients) {
    if (clients.isEmpty) {
      return _Empty(
        icon: _archive ? Iconsax.archive_1 : Iconsax.crown_1,
        title: _archive ? 'Архив пуст' : (_filterDate != null ? 'Нет клиентов на эту дату' : 'Пока нет VIP-клиентов'),
        subtitle: _archive ? 'Сюда попадают удалённые клиенты' : 'Создайте клиента кнопкой + или из чата',
      );
    }
    final repo = ref.read(vipRepositoryProvider);
    final grouped = _filterDate == null;
    final rows = grouped ? groupByDay<VipClient>(clients, vipDate) : clients.cast<Object>().toList();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(15, 2, 15, 24),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        if (row is String) {
          final cnt = clients.where((c) => dayLabel(vipDate(c)) == row).length;
          return softDayHeader(row, cnt, _vipRedDark);
        }
        final c = row as VipClient;
        return ArchiveActions(
          itemKey: ValueKey(c.id),
          archived: _archive,
          label: 'VIP-клиент «${c.name}»',
          onTap: _archive ? null : () => VipClientSheet.show(context, existing: c),
          onLongPress: () => copyPhone(context, c.phone),
          onArchive: () => repo.archive(c.id!, true),
          onRestore: () => repo.archive(c.id!, false),
          onDeleteForever: () => repo.delete(c.id!),
          child: _VipCard(c, onEditStatus: _archive ? null : () => _quickEditStatus(c)),
        );
      },
    );
  }
}

/// Цвет статуса VIP-клиента.
Color statusColor(VipStatus s) => switch (s) {
      VipStatus.awaitingArrival => const Color(0xFF8A96A0),
      VipStatus.met => const Color(0xFF378ADD),
      VipStatus.inHotel => const Color(0xFF13B0A0),
      VipStatus.inTreatment => const Color(0xFFEF9F27),
      VipStatus.preparingDeparture => const Color(0xFFD85A30),
      VipStatus.departed => const Color(0xFF7F77DD),
      VipStatus.completed => const Color(0xFF639922),
    };

class _VipCard extends StatelessWidget {
  const _VipCard(this.c, {this.onEditStatus});
  final VipClient c;
  final VoidCallback? onEditStatus;

  @override
  Widget build(BuildContext context) {
    final sc = statusColor(c.status);
    final arrival = c.arrivalDate ?? c.doctorAppointmentDate;
    final arrivalLabel = arrival != null ? '${arrival.day}.${arrival.month.toString().padLeft(2, '0')}' : null;

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
          CountryAvatar(phone: c.phone, name: c.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(c.name.isEmpty ? 'Без имени' : c.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: kInk, letterSpacing: -0.2)),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(children: [
                    Text(c.phone?.isNotEmpty == true ? formatPhone(c.phone) : (c.city ?? '—'),
                        maxLines: 1, style: const TextStyle(fontSize: 12.5, color: kSub)),
                    if (arrivalLabel != null) ...[
                      const SizedBox(width: 8),
                      const Icon(Iconsax.airplane, size: 12, color: kSub),
                      const SizedBox(width: 3),
                      Text(arrivalLabel, style: const TextStyle(fontSize: 12.5, color: kSub)),
                    ],
                  ]),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onEditStatus,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 96),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: sc.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(11)),
              child: Text(c.status.label, maxLines: 2, textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: sc, height: 1.15)),
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
              decoration: BoxDecoration(color: _vipRed.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(22)),
              child: Icon(icon, size: 34, color: _vipRed),
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
