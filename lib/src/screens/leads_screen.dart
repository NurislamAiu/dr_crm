import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/lead.dart';
import '../state/providers.dart';

const _teal = Color(0xFF13B0A0);
const _tealDark = Color(0xFF0E8F82);

/// Экран списка лидов (реальное время из Firestore, коллекция `leads`).
class LeadsScreen extends ConsumerWidget {
  const LeadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final stream = ref.watch(leadRepositoryProvider).watchAll();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('Лиды', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: StreamBuilder<List<Lead>>(
          stream: stream,
          builder: (context, snap) {
            if (snap.hasError) {
              return _Message(icon: Icons.cloud_off, title: 'Ошибка загрузки', subtitle: '${snap.error}');
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final leads = snap.data!;
            if (leads.isEmpty) {
              return const _Message(icon: Icons.bolt_rounded, title: 'Пока нет лидов', subtitle: 'Создайте лид из чата кнопкой ЛИД');
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              itemCount: leads.length,
              itemBuilder: (context, i) => _LeadCard(leads[i]),
            );
          },
        ),
      ),
    );
  }
}

class _LeadCard extends StatelessWidget {
  const _LeadCard(this.lead);
  final Lead lead;

  static String _money(num v) {
    final s = v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
    final parts = s.split('.');
    final intPart = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]} ');
    return parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = dark ? const Color(0xFF1B242B) : Colors.white;
    final sub = dark ? Colors.white60 : const Color(0xFF6A767D);

    final date = lead.appointmentDate != null ? DateFormat('dd.MM.yyyy').format(lead.appointmentDate!) : null;
    final time = lead.appointmentTime;
    final metaParts = <String>[?date, if (time != null && time.isNotEmpty) time];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(18),
        boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [_teal, _tealDark]),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: _teal.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 3))],
            ),
            alignment: Alignment.center,
            child: Text('№${lead.leadNumber ?? '—'}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(lead.name.isEmpty ? 'Без имени' : lead.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                const SizedBox(height: 3),
                if (metaParts.isNotEmpty)
                  Row(children: [
                    Icon(Icons.event, size: 13, color: sub),
                    const SizedBox(width: 4),
                    Text(metaParts.join(' · '), style: TextStyle(fontSize: 13, color: sub, fontWeight: FontWeight.w500)),
                  ]),
                if (lead.phone != null && lead.phone!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(children: [
                    Icon(Icons.phone, size: 13, color: sub),
                    const SizedBox(width: 4),
                    Text(lead.phone!, style: TextStyle(fontSize: 13, color: sub)),
                  ]),
                ],
              ],
            ),
          ),
          if (lead.prepayment != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: _teal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_money(lead.prepayment!),
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: _tealDark)),
                  Text('предоплата', style: TextStyle(fontSize: 9.5, color: _tealDark.withValues(alpha: 0.7))),
                ],
              ),
            ),
          ],
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
            Icon(icon, size: 56, color: _teal.withValues(alpha: 0.6)),
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
