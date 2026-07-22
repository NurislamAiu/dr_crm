import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/vip_client.dart';
import '../state/providers.dart';
import 'archive_actions.dart';
import 'day_utils.dart';
import 'vip_client_sheet.dart';

const _vipRed = Color(0xFFE23744);
const _vipRedDark = Color(0xFFC42232);

/// Экран списка VIP-клиентов (реальное время из Firestore, коллекция `clients`).
class VipClientsScreen extends ConsumerStatefulWidget {
  const VipClientsScreen({super.key});

  @override
  ConsumerState<VipClientsScreen> createState() => _VipClientsScreenState();
}

class _VipClientsScreenState extends ConsumerState<VipClientsScreen> {
  bool _archive = false;
  List<VipClient> _current = [];

  void _export() {
    final items = _current;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Список пуст')));
      return;
    }
    final b = StringBuffer();
    b.writeln('№\tТелефон\tИмя\tСтатус');
    for (var i = 0; i < items.length; i++) {
      final c = items[i];
      b.writeln('${i + 1}\t${c.phone ?? ''}\t${c.name}\t${c.status.label}');
    }
    final text = b.toString();
    Clipboard.setData(ClipboardData(text: text));
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Экспорт (${items.length})'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Закрыть')),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 18),
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final repo = ref.watch(vipRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(_archive ? 'Архив VIP' : 'VIP-клиенты', style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(icon: const Icon(Icons.ios_share_rounded), tooltip: 'Экспорт', onPressed: () => _export()),
          IconButton(
            icon: Icon(_archive ? Icons.list_alt_rounded : Icons.archive_outlined),
            tooltip: _archive ? 'Активные' : 'Архив',
            onPressed: () => setState(() => _archive = !_archive),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: StreamBuilder<List<VipClient>>(
          stream: repo.watchAll(),
          builder: (context, snap) {
            if (snap.hasError) {
              return _Message(icon: Icons.cloud_off, title: 'Ошибка загрузки', subtitle: '${snap.error}');
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final clients = snap.data!.where((c) => c.archived == _archive).toList();
            if (clients.isEmpty) {
              return _Message(
                icon: _archive ? Icons.archive_outlined : Icons.workspace_premium_rounded,
                title: _archive ? 'Архив пуст' : 'Пока нет VIP-клиентов',
                subtitle: _archive ? 'Сюда попадают удалённые клиенты' : 'Создайте клиента из чата кнопкой VIP',
              );
            }
            _current = clients;
            final rows = groupByDay<VipClient>(clients, (c) => c.createdAt);
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                if (row is String) {
                  final cnt = clients.where((c) => dayLabel(c.createdAt) == row).length;
                  return dayHeader(row, count: cnt);
                }
                final c = row as VipClient;
                return ArchiveActions(
                  itemKey: ValueKey(c.id),
                  archived: _archive,
                  label: 'VIP-клиент «${c.name}»',
                  onTap: _archive ? null : () => VipClientSheet.show(context, existing: c),
                  onArchive: () => repo.archive(c.id!, true),
                  onRestore: () => repo.archive(c.id!, false),
                  onDeleteForever: () => repo.delete(c.id!),
                  child: _VipCard(c),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

Color _statusColor(VipStatus s) => switch (s) {
      VipStatus.awaitingArrival => const Color(0xFF8A96A0),
      VipStatus.met => const Color(0xFF378ADD),
      VipStatus.inHotel => const Color(0xFF13B0A0),
      VipStatus.inTreatment => const Color(0xFFEF9F27),
      VipStatus.preparingDeparture => const Color(0xFFD85A30),
      VipStatus.departed => const Color(0xFF7F77DD),
      VipStatus.completed => const Color(0xFF639922),
    };

class _VipCard extends StatelessWidget {
  const _VipCard(this.c);
  final VipClient c;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = dark ? const Color(0xFF1B242B) : Colors.white;
    final sub = dark ? Colors.white60 : const Color(0xFF6A767D);
    final sc = _statusColor(c.status);

    final where = [c.city, c.country].where((e) => e != null && e.isNotEmpty).join(', ');
    final arrival = c.arrivalDate != null ? DateFormat('dd.MM').format(c.arrivalDate!) : null;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(18),
        boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [_vipRed, _vipRedDark]),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: _vipRed.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 3))],
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(c.name.isEmpty ? 'Без имени' : c.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(color: sc.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(9)),
                    child: Text(c.status.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: sc)),
                  ),
                ]),
                const SizedBox(height: 4),
                if (c.phone != null && c.phone!.isNotEmpty)
                  Row(children: [
                    Icon(Icons.phone, size: 13, color: sub),
                    const SizedBox(width: 4),
                    Text(c.phone!, style: TextStyle(fontSize: 13, color: sub)),
                  ]),
                if (where.isNotEmpty || arrival != null) ...[
                  const SizedBox(height: 2),
                  Row(children: [
                    if (where.isNotEmpty) ...[
                      Icon(Icons.place_outlined, size: 13, color: sub),
                      const SizedBox(width: 4),
                      Flexible(child: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: sub))),
                    ],
                    if (where.isNotEmpty && arrival != null) Text('  ·  ', style: TextStyle(fontSize: 13, color: sub)),
                    if (arrival != null) ...[
                      Icon(Icons.flight_land, size: 13, color: sub),
                      const SizedBox(width: 4),
                      Text(arrival, style: TextStyle(fontSize: 13, color: sub)),
                    ],
                  ]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = dark ? Colors.white54 : Colors.black45;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: _vipRed.withValues(alpha: 0.6)),
            const SizedBox(height: 14),
            Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: dark ? Colors.white : Colors.black87)),
            const SizedBox(height: 6),
            Text(subtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: c)),
          ],
        ),
      ),
    );
  }
}
