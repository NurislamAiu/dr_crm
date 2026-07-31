import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../data/presence_service.dart';
import '../data/risk_service.dart';
import '../state/providers.dart';
import 'risk_screen.dart';
import 'soft_ui.dart';

const _pageBg = Color(0xFFF1F8F6);

/// Аналитика для админа: кто из менеджеров работает (онлайн) и сколько
/// каждый сделал за период — сообщений, лидов, VIP.
class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  int _days = 0; // 0 = сегодня, 7, 30
  Map<String, int> _msgCounts = {};
  Map<String, Duration> _workByUid = {};
  bool _loadingCounts = false;
  String _countsKey = '';

  DateTime get _periodStart {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _days == 0 ? today : today.subtract(Duration(days: _days));
  }

  /// Подгрузить счётчики сообщений (агрегатные count) и часы работы
  /// (workSessions) по менеджерам.
  Future<void> _ensureCounts(List<String> uids) async {
    final key = '$_days|${uids.join(',')}';
    if (key == _countsKey || uids.isEmpty) return;
    _countsKey = key;
    _loadingCounts = true;
    final db = FirebaseFirestore.instance;
    final start = Timestamp.fromDate(_periodStart);

    final result = <String, int>{};
    for (final uid in uids) {
      try {
        final agg = await db
            .collection('messages')
            .where('direction', isEqualTo: 'outbound')
            .where('authorId', isEqualTo: uid)
            .where('createdAt', isGreaterThanOrEqualTo: start)
            .count()
            .get();
        result[uid] = agg.count ?? 0;
      } catch (_) {
        result[uid] = -1; // индекс ещё строится / нет сети
      }
    }

    final work = <String, Duration>{};
    try {
      final snap = await db.collection('workSessions').where('startAt', isGreaterThanOrEqualTo: start).get();
      for (final d in snap.docs) {
        final data = d.data();
        final uid = data['uid'] as String?;
        final s = (data['startAt'] as Timestamp?)?.toDate();
        final e = ((data['endAt'] ?? data['lastActiveAt']) as Timestamp?)?.toDate();
        if (uid == null || s == null || e == null) continue;
        final dur = e.difference(s);
        if (dur.inSeconds <= 0) continue;
        work[uid] = (work[uid] ?? Duration.zero) + dur;
      }
    } catch (_) {}

    if (!mounted || key != _countsKey) return;
    setState(() {
      _msgCounts = result;
      _workByUid = work;
      _loadingCounts = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final leads = ref.watch(leadsListProvider).value ?? const [];
    final vips = ref.watch(vipClientsListProvider).value ?? const [];
    final start = _periodStart;

    int leadsBy(String uid) => leads.where((l) => l.createdBy == uid && (l.createdAt?.isAfter(start) ?? false)).length;
    int vipsBy(String uid) => vips.where((c) => c.createdBy == uid && (c.createdAt?.isAfter(start) ?? false)).length;
    final leadsTotal = leads.where((l) => l.createdAt?.isAfter(start) ?? false).length;

    // Кэшированные провайдеры: не пересоздаём подписки при каждом setState.
    final managers = ref.watch(managersProvider).value ?? const <Map<String, dynamic>>[];
    final onlineUsers = ref.watch(presenceUsersProvider).value ?? const <PresenceUser>[];

    // Контроль подозрительной активности за тот же период.
    final risks = ref.watch(riskEventsProvider((days: _days, uid: null, day: null))).value ?? const <RiskEvent>[];
    final riskByUid = <String, int>{};
    final riskHighByUid = <String, int>{};
    for (final e in risks) {
      riskByUid[e.authorId] = (riskByUid[e.authorId] ?? 0) + 1;
      if (e.isHigh) riskHighByUid[e.authorId] = (riskHighByUid[e.authorId] ?? 0) + 1;
    }
    return Scaffold(
      backgroundColor: _pageBg,
      body: Builder(
        builder: (context) {
          final uids = managers.map((m) => m['id'] as String).toList()..sort();
          // Счётчики сообщений обновляем после кадра (не во время build).
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureCounts(uids));

          return Builder(
            builder: (context) {
              final online = {for (final u in onlineUsers) u.uid};
              final msgTotal = _msgCounts.values.where((v) => v > 0).fold<int>(0, (s, v) => s + v);

              // Онлайн выше, дальше по числу сообщений.
              final sorted = [...managers]..sort((a, b) {
                  final ao = online.contains(a['id']) ? 0 : 1;
                  final bo = online.contains(b['id']) ? 0 : 1;
                  if (ao != bo) return ao - bo;
                  return (_msgCounts[b['id']] ?? 0).compareTo(_msgCounts[a['id']] ?? 0);
                });

              return Column(
                children: [
                  SoftHeader(
                    color: kTeal,
                    colorDeep: kTealDeep,
                    title: 'Аналитика',
                    dateLabel: weekdayDateRu(DateTime.now()),
                    actions: const [],
                    showBack: true,
                    strip: Column(children: [
                      _periodChips(),
                      const SizedBox(height: 12),
                      Row(children: [
                        HeaderStat(value: '${online.length}', label: 'сейчас в сети'),
                        const SizedBox(width: 9),
                        HeaderStat(value: _loadingCounts ? '…' : '$msgTotal', label: 'сообщений'),
                        const SizedBox(width: 9),
                        HeaderStat(value: '$leadsTotal', label: 'лидов'),
                      ]),
                    ]),
                  ),
                  Expanded(
                    child: Container(
                      transform: Matrix4.translationValues(0, -22, 0),
                      decoration: const BoxDecoration(
                        color: _pageBg,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                      ),
                      child: managers.isEmpty
                          ? const Center(child: CircularProgressIndicator())
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(15, 22, 15, 28),
                              itemCount: sorted.length + 1,
                              itemBuilder: (context, i) {
                                if (i == 0) {
                                  return _RiskBanner(
                                    total: risks.length,
                                    high: risks.where((e) => e.isHigh).length,
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => RiskScreen(days: _days)),
                                    ),
                                  );
                                }
                                final m = sorted[i - 1];
                                final uid = m['id'] as String;
                                final name = (m['name'] as String?)?.trim() ?? '';
                                return _ManagerCard(
                                  name: name,
                                  role: (m['role'] as String?) ?? 'manager',
                                  isActive: m['isActive'] != false,
                                  online: online.contains(uid),
                                  messages: _msgCounts[uid],
                                  leads: leadsBy(uid),
                                  vips: vipsBy(uid),
                                  worked: _workByUid[uid],
                                  risks: riskByUid[uid] ?? 0,
                                  risksHigh: riskHighByUid[uid] ?? 0,
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => ManagerDetailScreen(uid: uid, name: name),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _periodChips() {
    const items = [(0, 'Сегодня'), (7, '7 дней'), (30, '30 дней')];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        for (final (d, label) in items)
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                _days = d;
                _countsKey = ''; // форсируем перезагрузку счётчиков
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _days == d ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: _days == d ? FontWeight.w700 : FontWeight.w500,
                        color: _days == d ? kTealDeep : Colors.white.withValues(alpha: 0.85))),
              ),
            ),
          ),
      ]),
    );
  }
}

/// «5 ч 12 м» / «42 м».
String fmtDuration(Duration d) {
  if (d.inMinutes < 1) return '<1 м';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return '$m м';
  return m == 0 ? '$h ч' : '$h ч $m м';
}

/// Плашка контроля: сколько подозрительных сообщений и рассылок за период.
class _RiskBanner extends StatelessWidget {
  const _RiskBanner({required this.total, required this.high, required this.onTap});
  final int total;
  final int high;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final clean = total == 0;
    final accent = clean ? kTealDeep : (high > 0 ? kRiskDeep : const Color(0xFFB07A10));
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: clean ? Colors.transparent : accent.withValues(alpha: 0.30)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                child: Icon(clean ? Iconsax.shield_tick : Iconsax.warning_2, size: 21, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Подозрительная активность',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
                  const SizedBox(height: 2),
                  Text(
                    clean
                        ? 'Нарушений нет — сообщения и рассылки в норме'
                        : '$total ${_evWord(total)}${high > 0 ? ' · $high важных' : ''} — кто и что отправлял',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: clean ? kSub : accent, fontWeight: clean ? FontWeight.w400 : FontWeight.w600),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              const Icon(Iconsax.arrow_right_3, size: 18, color: kSub),
            ]),
          ),
        ),
      ),
    );
  }

  static String _evWord(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'событие';
    if ([2, 3, 4].contains(n % 10) && ![12, 13, 14].contains(n % 100)) return 'события';
    return 'событий';
  }
}

class _ManagerCard extends StatelessWidget {
  const _ManagerCard({
    required this.name,
    required this.role,
    required this.isActive,
    required this.online,
    required this.messages,
    required this.leads,
    required this.vips,
    required this.worked,
    required this.risks,
    required this.risksHigh,
    required this.onTap,
  });

  final String name;
  final String role;
  final bool isActive;
  final bool online;
  final int? messages; // null = загрузка, -1 = недоступно
  final int leads;
  final int vips;
  final Duration? worked;

  /// Сколько подозрительных событий у менеджера за период (и из них важных).
  final int risks;
  final int risksHigh;
  final VoidCallback onTap;

  bool get _isAdmin => role == 'admin' || role == 'administrator';

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            child: Column(children: [
        Row(children: [
          Stack(clipBehavior: Clip.none, children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: (online ? kTeal : kSub).withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(15),
              ),
              alignment: Alignment.center,
              child: Text(initial,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: online ? kTealDeep : kSub)),
            ),
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: online ? const Color(0xFF2ECC71) : const Color(0xFFC3CFCB),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.5),
                ),
              ),
            ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(name.isEmpty ? 'Менеджер' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
                ),
                if (_isAdmin) ...[
                  const SizedBox(width: 6),
                  const Icon(Iconsax.shield_tick, size: 14, color: kTealDeep),
                ],
                if (!isActive) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFFFBEDEC), borderRadius: BorderRadius.circular(7)),
                    child: const Text('отключён',
                        style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Color(0xFFC6403C))),
                  ),
                ],
                if (risks > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: (risksHigh > 0 ? kRiskDeep : const Color(0xFFB07A10)).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Iconsax.warning_2, size: 10, color: risksHigh > 0 ? kRiskDeep : const Color(0xFFB07A10)),
                      const SizedBox(width: 3),
                      Text('$risks',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: risksHigh > 0 ? kRiskDeep : const Color(0xFFB07A10))),
                    ]),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              Text(online ? 'в сети' : 'не в сети',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: online ? FontWeight.w600 : FontWeight.w400,
                      color: online ? const Color(0xFF23A35F) : kSub)),
            ]),
          ),
          const Icon(Iconsax.arrow_right_3, size: 17, color: kSub),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _metric(Iconsax.message, messages == null ? '…' : (messages! < 0 ? '—' : '${messages!}'), 'сообщ.'),
          const SizedBox(width: 8),
          _metric(Iconsax.flash_1, '$leads', 'лидов'),
          const SizedBox(width: 8),
          _metric(Iconsax.crown_1, '$vips', 'VIP'),
          const SizedBox(width: 8),
          _metric(Iconsax.clock, worked == null ? '—' : fmtDuration(worked!), 'в прилож.'),
        ]),
      ]),
          ),
        ),
      ),
    );
  }

  Widget _metric(IconData icon, String value, String label) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
          decoration: BoxDecoration(color: const Color(0xFFF2F6F5), borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 13, color: kTealDeep),
                const SizedBox(width: 4),
                Text(value,
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: kInk,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ]),
            ),
            const SizedBox(height: 1),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label, maxLines: 1, style: const TextStyle(fontSize: 10, color: kSub)),
            ),
          ]),
        ),
      );
}

/// Одна рабочая сессия менеджера.
class _Session {
  _Session({required this.start, required this.end, required this.ongoing});
  final DateTime start;
  final DateTime end;
  final bool ongoing;
  Duration get dur => end.difference(start);
}

/// Сводка одного дня.
class _DaySummary {
  _DaySummary(this.day, this.sessions);
  final DateTime day;
  final List<_Session> sessions;
  Duration get total => sessions.fold(Duration.zero, (s, x) => s + x.dur);
  DateTime get firstIn => sessions.map((s) => s.start).reduce((a, b) => a.isBefore(b) ? a : b);
  DateTime get lastOut => sessions.map((s) => s.end).reduce((a, b) => a.isAfter(b) ? a : b);
  bool get ongoing => sessions.any((s) => s.ongoing);
}

/// Детальная аналитика менеджера: сколько часов работал по дням,
/// когда зашёл и когда вышел из приложения (последние 14 дней).
class ManagerDetailScreen extends StatefulWidget {
  const ManagerDetailScreen({super.key, required this.uid, required this.name, this.db});
  final String uid;
  final String name;

  /// Подменяется в превью (fake Firestore); в приложении — обычный instance.
  final FirebaseFirestore? db;

  @override
  State<ManagerDetailScreen> createState() => _ManagerDetailScreenState();
}

class _ManagerDetailScreenState extends State<ManagerDetailScreen> {
  static const _daysBack = 14;
  List<_DaySummary>? _summaries;
  String? _error;
  final _expanded = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _summaries = null;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day).subtract(const Duration(days: _daysBack - 1));
      final snap = await (widget.db ?? FirebaseFirestore.instance)
          .collection('workSessions')
          .where('uid', isEqualTo: widget.uid)
          .where('startAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .orderBy('startAt', descending: true)
          .get();

      final byDay = <int, List<_Session>>{};
      for (final d in snap.docs) {
        final data = d.data();
        final s = (data['startAt'] as Timestamp?)?.toDate();
        final endTs = ((data['endAt'] ?? data['lastActiveAt']) as Timestamp?)?.toDate();
        if (s == null || endTs == null) continue;
        final ongoing = data['endAt'] == null && now.difference(endTs).inMinutes < 3;
        final e = ongoing ? now : endTs;
        if (e.isBefore(s)) continue;
        final key = s.year * 10000 + s.month * 100 + s.day;
        (byDay[key] ??= []).add(_Session(start: s, end: e, ongoing: ongoing));
      }
      final keys = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
      final list = [
        for (final k in keys)
          _DaySummary(DateTime(k ~/ 10000, (k % 10000) ~/ 100, k % 100), byDay[k]!..sort((a, b) => a.start.compareTo(b.start))),
      ];
      if (mounted) setState(() => _summaries = list);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  static String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final s = _summaries ?? const <_DaySummary>[];
    final total = s.fold(Duration.zero, (a, d) => a + d.total);
    final avg = s.isEmpty ? Duration.zero : Duration(minutes: total.inMinutes ~/ s.length);

    return Scaffold(
      backgroundColor: _pageBg,
      body: Column(
        children: [
          SoftHeader(
            color: kTeal,
            colorDeep: kTealDeep,
            title: widget.name.isEmpty ? 'Менеджер' : widget.name,
            dateLabel: 'Активность · $_daysBack дней',
            showBack: true,
            actions: [
              SoftHeaderButton(
                icon: Iconsax.warning_2,
                tooltip: 'Подозрительная активность',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RiskScreen(uid: widget.uid, name: widget.name, days: 30),
                  ),
                ),
              ),
              SoftHeaderButton(icon: Icons.refresh_rounded, tooltip: 'Обновить', onTap: _load),
            ],
            strip: Row(children: [
              HeaderStat(value: _summaries == null ? '…' : fmtDuration(total), label: 'в приложении'),
              const SizedBox(width: 9),
              HeaderStat(value: _summaries == null ? '…' : '${s.length}', label: 'дней работал'),
              const SizedBox(width: 9),
              HeaderStat(value: _summaries == null ? '…' : fmtDuration(avg), label: 'среднее/день'),
            ]),
          ),
          Expanded(
            child: Container(
              transform: Matrix4.translationValues(0, -22, 0),
              decoration: const BoxDecoration(
                color: _pageBg,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: _body(s),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(List<_DaySummary> s) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text('Ошибка: $_error\n\nЕсли индекс ещё строится — попробуйте через пару минут.',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: kSub)),
        ),
      );
    }
    if (_summaries == null) return const Center(child: CircularProgressIndicator());
    if (s.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text('Пока нет данных.\nСессии записываются с момента этого обновления приложения.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: kSub)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(15, 22, 15, 28),
      itemCount: s.length,
      itemBuilder: (context, i) {
        final d = s[i];
        final open = _expanded.contains(i);
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => setState(() => open ? _expanded.remove(i) : _expanded.add(i)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // День слева, крупные часы справа.
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(humanDate(d.day),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kInk, letterSpacing: -0.2)),
                        const SizedBox(height: 2),
                        Text(
                          d.ongoing ? 'сейчас в приложении' : '${d.sessions.length} ${_sesWord(d.sessions.length)}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: d.ongoing ? FontWeight.w700 : FontWeight.w400,
                              color: d.ongoing ? const Color(0xFF23A35F) : kSub),
                        ),
                      ]),
                    ),
                    Text(fmtDuration(d.total),
                        style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: kTealDeep,
                            letterSpacing: -0.4,
                            fontFeatures: [FontFeature.tabularFigures()])),
                  ]),
                  const SizedBox(height: 12),
                  // Шкала дня 00–24: закрашено, когда был в приложении.
                  _DayTimeline(sessions: d.sessions),
                  const SizedBox(height: 12),
                  // Зашёл / вышел — крупно и по краям.
                  Row(children: [
                    _inOut(Iconsax.login, 'Зашёл', _hm(d.firstIn)),
                    const Spacer(),
                    _inOut(Iconsax.logout, 'Вышел', d.ongoing ? '—' : _hm(d.lastOut)),
                    const SizedBox(width: 12),
                    Icon(open ? Iconsax.arrow_up_2 : Iconsax.arrow_down_1, size: 15, color: kSub),
                  ]),
                  if (open) ...[
                    const SizedBox(height: 12),
                    Container(height: 1, color: Colors.black.withValues(alpha: 0.05)),
                    const SizedBox(height: 10),
                    for (final ses in d.sessions)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: ses.ongoing ? const Color(0xFF2ECC71) : kTeal,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text('${_hm(ses.start)} — ${ses.ongoing ? 'сейчас' : _hm(ses.end)}',
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: kInk,
                                  fontFeatures: [FontFeature.tabularFigures()])),
                          const Spacer(),
                          Text(fmtDuration(ses.dur),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kSub)),
                        ]),
                      ),
                  ],
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _sesWord(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'заход';
    if ([2, 3, 4].contains(n % 10) && ![12, 13, 14].contains(n % 100)) return 'захода';
    return 'заходов';
  }

  Widget _inOut(IconData icon, String label, String time) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 15, color: kTealDeep),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 10.5, color: kSub)),
          Text(time,
              style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: kInk,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ]),
      ]);
}

/// Полоса дня 00–24 с закрашенными отрезками работы.
class _DayTimeline extends StatelessWidget {
  const _DayTimeline({required this.sessions});
  final List<_Session> sessions;

  static double _frac(DateTime d) => (d.hour * 60 + d.minute) / 1440.0;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SizedBox(
        height: 10,
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          return Stack(children: [
            Container(
              width: w,
              decoration: BoxDecoration(color: const Color(0xFFECF2F0), borderRadius: BorderRadius.circular(5)),
            ),
            for (final s in sessions)
              Positioned(
                left: w * _frac(s.start),
                width: (w * (_sameDay(s.start, s.end) ? _frac(s.end) : 1.0) - w * _frac(s.start)).clamp(4.0, w),
                top: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: s.ongoing ? const Color(0xFF2ECC71) : kTeal,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
          ]);
        }),
      ),
      const SizedBox(height: 5),
      const Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('00', style: TextStyle(fontSize: 9.5, color: kSub)),
          Text('06', style: TextStyle(fontSize: 9.5, color: kSub)),
          Text('12', style: TextStyle(fontSize: 9.5, color: kSub)),
          Text('18', style: TextStyle(fontSize: 9.5, color: kSub)),
          Text('24', style: TextStyle(fontSize: 9.5, color: kSub)),
        ],
      ),
    ]);
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
}
