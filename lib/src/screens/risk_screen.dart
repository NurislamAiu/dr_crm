import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../data/firestore_chat_repository.dart';
import '../data/risk_service.dart';
import '../state/providers.dart';
import 'firebase_chats.dart';
import 'soft_ui.dart';

const _pageBg = Color(0xFFFBF3F2);
const kRisk = Color(0xFFD2453F);
const kRiskDeep = Color(0xFF9E2A26);
const _amber = Color(0xFFB07A10);

/// Описание признака: заголовок, пояснение, иконка.
const Map<String, (String, String, IconData)> kRiskKinds = {
  'card': ('Реквизиты в сообщении', 'В тексте номер карты, IBAN или Kaspi — деньги могут уйти мимо клиники', Iconsax.card),
  'mass': ('Ручная рассылка', 'Один и тот же текст ушёл 5+ разным номерам за час, минуя модуль рассылки', Iconsax.send_2),
  'blast': ('Запустил рассылку', 'Серверная рассылка по списку номеров', Iconsax.send_1),
  'phone': ('Чужой номер в тексте', 'Менеджер отправил телефон, которого нет в белом списке клиники', Iconsax.call),
  'burst': ('Слишком быстрый темп', 'Много разных чатов за 5 минут — WhatsApp считает это спамом', Iconsax.flash_1),
  'cold': ('Первое сообщение', 'Клиент нам ни разу не писал — главная причина блокировок', Iconsax.user_add),
  'deleted': ('Удалил сообщение', 'Менеджер удалил своё сообщение из переписки', Iconsax.trash),
  'link': ('Ссылка новому контакту', 'Ссылка в первом сообщении почти всегда ведёт к бану', Iconsax.link),
  'night': ('Вне рабочих часов', 'Отправлено не в 08:00–23:00 по Астане', Iconsax.moon),
};

String riskLabel(String kind) => kRiskKinds[kind]?.$1 ?? kind;
IconData riskIcon(String kind) => kRiskKinds[kind]?.$3 ?? Iconsax.warning_2;

Color riskColor(String severity) => switch (severity) {
      'high' => kRiskDeep,
      'medium' => _amber,
      _ => kSub,
    };

/// Журнал подозрительной активности: что и кто отправлял. Открывается из
/// аналитики (общий список) или из карточки менеджера (только его события).
class RiskScreen extends ConsumerStatefulWidget {
  const RiskScreen({super.key, this.uid, this.name, this.days = 7});

  /// Фильтр по менеджеру (null — все).
  final String? uid;
  final String? name;
  final int days;

  @override
  ConsumerState<RiskScreen> createState() => _RiskScreenState();
}

enum _Filter { all, high, blast, money, cold }

class _RiskScreenState extends ConsumerState<RiskScreen> {
  late int _days = widget.days;

  /// Выбран конкретный день (вчера или дата из календаря) — тогда `_days`
  /// не используется.
  DateTime? _day;
  _Filter _filter = _Filter.all;

  static DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// Заголовок периода для шапки.
  String get _periodLabel {
    final d = _day;
    if (d != null) return humanDate(d);
    return switch (_days) { 0 => 'Сегодня', 7 => 'За 7 дней', _ => 'За 30 дней' };
  }

  bool _matches(RiskEvent e) => switch (_filter) {
        _Filter.all => true,
        _Filter.high => e.isHigh,
        _Filter.blast => e.kinds.contains('mass') || e.kinds.contains('blast') || e.kinds.contains('burst'),
        _Filter.money => e.kinds.contains('card') || e.kinds.contains('phone'),
        _Filter.cold => e.kinds.contains('cold') || e.kinds.contains('link'),
      };

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(riskEventsProvider((days: _days, uid: widget.uid, day: _day)));
    final all = async.value ?? const <RiskEvent>[];
    final list = all.where(_matches).toList();
    final high = all.where((e) => e.isHigh).length;
    final people = all.map((e) => e.authorId).toSet().length;

    return Scaffold(
      backgroundColor: _pageBg,
      body: Column(children: [
        SoftHeader(
          color: kRisk,
          colorDeep: kRiskDeep,
          title: widget.name?.isNotEmpty == true ? widget.name! : 'Контроль',
          dateLabel: '${widget.uid == null ? 'Подозрительная активность' : 'Нарушения менеджера'} · $_periodLabel',
          showBack: true,
          actions: [
            SoftHeaderButton(
              icon: Iconsax.calendar_1,
              tooltip: 'Выбрать день',
              accent: kRiskDeep,
              active: _day != null,
              onTap: _pickDay,
            ),
            if (widget.uid == null)
              SoftHeaderButton(
                icon: Iconsax.setting_4,
                tooltip: 'Свои номера',
                accent: kRiskDeep,
                onTap: _editAllowed,
              ),
          ],
          strip: Column(children: [
            _periodChips(),
            const SizedBox(height: 12),
            Row(children: [
              HeaderStat(value: async.isLoading && all.isEmpty ? '…' : '${all.length}', label: 'событий'),
              const SizedBox(width: 9),
              HeaderStat(value: '$high', label: 'важных'),
              const SizedBox(width: 9),
              HeaderStat(value: widget.uid == null ? '$people' : '${list.length}', label: widget.uid == null ? 'менеджеров' : 'в фильтре'),
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
            child: Column(children: [
              const SizedBox(height: 14),
              if (widget.uid == null) _queueCard(),
              _filterRow(all),
              Expanded(child: _body(async.isLoading && all.isEmpty, list, async.hasError)),
            ]),
          ),
        ),
      ]),
    );
  }

  /// Сегодня · Вчера · 7 дней · 30 дней (любой другой день — через календарь).
  Widget _periodChips() {
    final yesterday = _today.subtract(const Duration(days: 1));
    final items = <(String, bool, VoidCallback)>[
      ('Сегодня', _day == null && _days == 0, () => setState(() { _day = null; _days = 0; })),
      ('Вчера', _day != null && _sameDay(_day!, yesterday), () => setState(() => _day = yesterday)),
      ('7 дней', _day == null && _days == 7, () => setState(() { _day = null; _days = 7; })),
      ('30 дней', _day == null && _days == 30, () => setState(() { _day = null; _days = 30; })),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        for (final (label, sel, onTap) in items)
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: sel ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label,
                      maxLines: 1,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                          color: sel ? kRiskDeep : Colors.white.withValues(alpha: 0.85))),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  /// Очередь отправки: сообщения, придержанные лимитом темпа.
  Widget _queueCard() {
    final n = ref.watch(queueSizeProvider).value ?? 0;
    if (n == 0) return const SizedBox.shrink();
    final lim = ref.watch(sendLimitsProvider).value ?? const SendLimits();
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 15, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kTeal.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Iconsax.clock, size: 18, color: kTealDeep),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('В очереди ${n >= 200 ? '200+' : '$n'}',
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: kInk)),
              Text('Уйдут сами, не быстрее ${lim.hourLimit} сообщений в час',
                  style: const TextStyle(fontSize: 12, color: kSub)),
            ]),
          ),
        ]),
      ),
    );
  }

  /// Любой день из календаря (сброс — снова период «сегодня»).
  Future<void> _pickDay() async {
    final res = await showSoftDatePicker(context, selected: _day, accent: kRiskDeep);
    if (!mounted || res == null) return;
    setState(() {
      if (res == clearDateSentinel) {
        _day = null;
        _days = 0;
      } else if (res is DateTime) {
        _day = DateTime(res.year, res.month, res.day);
      }
    });
  }

  Widget _filterRow(List<RiskEvent> all) {
    int cnt(_Filter f) {
      final saved = _filter;
      _filter = f;
      final n = all.where(_matches).length;
      _filter = saved;
      return n;
    }

    const items = [
      (_Filter.all, 'Все'),
      (_Filter.high, 'Важные'),
      (_Filter.blast, 'Рассылки'),
      (_Filter.money, 'Реквизиты'),
      (_Filter.cold, 'Холодные'),
    ];
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (f, label) = items[i];
          final sel = _filter == f;
          final n = cnt(f);
          return GestureDetector(
            onTap: () => setState(() => _filter = f),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sel ? kRiskDeep : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: sel ? kRiskDeep : const Color(0xFFEADCDB)),
              ),
              child: Text(n > 0 ? '$label · $n' : label,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: sel ? FontWeight.w700 : FontWeight.w600,
                      color: sel ? Colors.white : kSub)),
            ),
          );
        },
      ),
    );
  }

  Widget _body(bool loading, List<RiskEvent> list, bool error) {
    if (loading) return const Center(child: CircularProgressIndicator(color: kRiskDeep));
    if (error) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text('Не удалось загрузить журнал.\nЕсли индекс ещё строится — попробуйте через пару минут.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: kSub)),
        ),
      );
    }
    if (list.isEmpty) {
      return SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 60, 28, 28),
          child: Column(children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(22)),
              child: const Icon(Iconsax.shield_tick, size: 30, color: kTealDeep),
            ),
            const SizedBox(height: 14),
            const Text('Всё чисто',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kInk)),
            const SizedBox(height: 6),
            const Text('За выбранный период подозрительных сообщений и рассылок не было.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: kSub)),
          ]),
        ),
      );
    }

    // Группировка по дням: сначала свежие.
    final byDay = <int, List<RiskEvent>>{};
    for (final e in list) {
      final d = e.createdAt ?? DateTime.now();
      (byDay[d.year * 10000 + d.month * 100 + d.day] ??= []).add(e);
    }
    final keys = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    final rows = <Widget>[];
    for (final k in keys) {
      final day = DateTime(k ~/ 10000, (k % 10000) ~/ 100, k % 100);
      final items = byDay[k]!;
      rows.add(softDayHeader(humanDate(day), items.length, kRiskDeep));
      for (final e in items) {
        rows.add(_RiskCard(event: e, showAuthor: widget.uid == null, onTap: () => _details(e)));
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(15, 4, 15, 28),
      children: rows,
    );
  }

  /// Подробности события: полный текст, что именно не так, переход в чат.
  Future<void> _details(RiskEvent e) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (sheet) {
        final time = e.createdAt;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(color: const Color(0xFFE2E8E6), borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: riskColor(e.severity).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(riskIcon(e.mainKind), size: 20, color: riskColor(e.severity)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.authorName.isEmpty ? 'Менеджер' : e.authorName,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kInk)),
                    Text(
                      time == null ? '' : '${humanDate(time)}, ${_hm(time)}',
                      style: const TextStyle(fontSize: 12.5, color: kSub),
                    ),
                  ]),
                ),
              ]),
              const SizedBox(height: 16),
              for (final k in e.kinds) ...[
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(riskIcon(k), size: 15, color: riskColor(e.severity)),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(riskLabel(k), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: kInk)),
                      Text(kRiskKinds[k]?.$2 ?? '', style: const TextStyle(fontSize: 12, color: kSub, height: 1.35)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 10),
              ],
              if (e.count != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('Получателей: ${e.count}',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kInk)),
                ),
              if (e.text.trim().isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
                  decoration: BoxDecoration(color: const Color(0xFFF4F7F6), borderRadius: BorderRadius.circular(16)),
                  child: Text(e.text, style: const TextStyle(fontSize: 13.5, color: kInk, height: 1.4)),
                ),
                const SizedBox(height: 14),
              ],
              Row(children: [
                if ((e.phone ?? '').isNotEmpty) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kInk,
                        side: const BorderSide(color: Color(0xFFE2E8E6)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      ),
                      icon: const Icon(Iconsax.copy, size: 17),
                      label: const Text('Номер', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                      onPressed: () {
                        Navigator.pop(sheet);
                        copyPhone(context, e.phone);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: kTealDeep,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      ),
                      icon: const Icon(Iconsax.message, size: 17),
                      label: const Text('Открыть чат', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                      onPressed: () {
                        Navigator.pop(sheet);
                        _openChat(e);
                      },
                    ),
                  ),
                ] else
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: kTealDeep,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      ),
                      onPressed: () => Navigator.pop(sheet),
                      child: const Text('Понятно', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ]),
            ]),
          ),
        );
      },
    );
  }

  /// Настройки контроля: лимит темпа и свои номера.
  Future<void> _editAllowed() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => const _ControlSettingsSheet(),
    );
  }

  void _openChat(RiskEvent e) {
    final id = e.phone ?? '';
    if (id.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FirebaseChatScreen(
          conversation: FsConversation(
            id: id,
            name: '+$id',
            phone: id,
            preview: null,
            lastMessageAt: null,
            unreadCount: 0,
          ),
        ),
      ),
    );
  }

  static String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// Настройки контроля: лимит темпа отправки + белый список номеров
/// (config/risk). Правит только админ — правила Firestore это закрывают.
class _ControlSettingsSheet extends ConsumerStatefulWidget {
  const _ControlSettingsSheet();

  @override
  ConsumerState<_ControlSettingsSheet> createState() => _ControlSettingsSheetState();
}

class _ControlSettingsSheetState extends ConsumerState<_ControlSettingsSheet> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save(List<String> next) async {
    setState(() => _busy = true);
    try {
      await ref.read(riskServiceProvider).setAllowedPhones(next);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveLimits(SendLimits l) async {
    setState(() => _busy = true);
    try {
      await ref.read(riskServiceProvider).setLimits(l);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Шаговый выбор числа (менеджерам и админу удобнее, чем клавиатура).
  Widget _stepper({
    required String label,
    required String hint,
    required int value,
    required int step,
    required int min,
    required int max,
    required ValueChanged<int> onChange,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kInk)),
              Text(hint, style: const TextStyle(fontSize: 11.5, color: kSub)),
            ]),
          ),
          _stepBtn(Icons.remove_rounded, _busy || value <= min ? null : () => onChange((value - step).clamp(min, max))),
          SizedBox(
            width: 56,
            child: Text('$value',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kInk)),
          ),
          _stepBtn(Icons.add_rounded, _busy || value >= max ? null : () => onChange((value + step).clamp(min, max))),
        ]),
      );

  Widget _stepBtn(IconData icon, VoidCallback? onTap) => Material(
        color: const Color(0xFFF2F6F5),
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, size: 18, color: onTap == null ? kSub.withValues(alpha: 0.4) : kTealDeep),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final phones = ref.watch(allowedPhonesProvider).value ?? const <String>[];
    final lim = ref.watch(sendLimitsProvider).value ?? const SendLimits();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 14, 20, MediaQuery.of(context).viewInsets.bottom + 18),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(color: const Color(0xFFE2E8E6), borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Лимит темпа', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kInk)),
          const SizedBox(height: 4),
          const Text(
            'Сверх лимита сообщения не теряются — они встают в очередь и уходят сами, ровным темпом.',
            style: TextStyle(fontSize: 12.5, color: kSub, height: 1.35),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: kTealDeep,
            value: lim.enabled,
            onChanged: _busy ? null : (v) => _saveLimits(lim.copyWith(enabled: v)),
            title: const Text('Ограничивать отправку',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kInk)),
            subtitle: const Text('Выключать не советую — именно всплески привели к бану',
                style: TextStyle(fontSize: 11.5, color: kSub)),
          ),
          const SizedBox(height: 6),
          _stepper(
            label: 'В час',
            hint: 'было до 312 — безопасно 100–150',
            value: lim.hourLimit,
            step: 10,
            min: 10,
            max: 400,
            onChange: (v) => _saveLimits(lim.copyWith(hourLimit: v)),
          ),
          _stepper(
            label: 'В сутки',
            hint: 'было до 2664 — безопасно 700–1000',
            value: lim.dayLimit,
            step: 50,
            min: 50,
            max: 3000,
            onChange: (v) => _saveLimits(lim.copyWith(dayLimit: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: kTealDeep,
            value: lim.queueMass,
            onChanged: _busy ? null : (v) => _saveLimits(lim.copyWith(queueMass: v)),
            title: const Text('Одинаковый текст — через очередь',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kInk)),
            subtitle: const Text('С 5-го адресата подряд текст рассылается с паузами',
                style: TextStyle(fontSize: 11.5, color: kSub)),
          ),
          const SizedBox(height: 10),
          Container(height: 1, color: Colors.black.withValues(alpha: 0.06)),
          const SizedBox(height: 16),
          const Text('Свои номера', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kInk)),
          const SizedBox(height: 4),
          const Text(
            'Номера клиники, которые можно отправлять клиентам. Всё остальное в тексте помечается как «чужой номер».',
            style: TextStyle(fontSize: 12.5, color: kSub, height: 1.35),
          ),
          const SizedBox(height: 14),
          for (final p in phones)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                const Icon(Iconsax.call, size: 16, color: kTealDeep),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(formatPhone(p),
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: kInk)),
                ),
                IconButton(
                  icon: const Icon(Iconsax.trash, size: 17, color: kRiskDeep),
                  onPressed: _busy ? null : () => _save([...phones]..remove(p)),
                ),
              ]),
            ),
          if (phones.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Список пуст', style: TextStyle(fontSize: 13, color: kSub)),
            ),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  hintText: '+7 777 000 00 00',
                  filled: true,
                  fillColor: const Color(0xFFF4F7F6),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: kTealDeep,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              onPressed: _busy
                  ? null
                  : () {
                      final v = _ctrl.text.replaceAll(RegExp(r'\D'), '');
                      if (v.length < 10 || phones.contains(v)) return;
                      _ctrl.clear();
                      _save([...phones, v]);
                    },
              child: const Text('Добавить', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
          ]),
          ]),
        ),
      ),
    );
  }
}

class _RiskCard extends StatelessWidget {
  const _RiskCard({required this.event, required this.showAuthor, required this.onTap});
  final RiskEvent event;
  final bool showAuthor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final color = riskColor(e.severity);
    final t = e.createdAt;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          onLongPress: () => copyPhone(context, e.phone),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(13)),
                  child: Icon(riskIcon(e.mainKind), size: 19, color: color),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text(riskLabel(e.mainKind),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: kInk)),
                      ),
                      if (t != null)
                        Text('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: kSub,
                                fontFeatures: [FontFeature.tabularFigures()])),
                    ]),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (showAuthor) (e.authorName.isEmpty ? 'Менеджер' : e.authorName),
                        if ((e.phone ?? '').isNotEmpty) formatPhone(e.phone),
                        if (e.count != null) '${e.count} получателей',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: kSub),
                    ),
                  ]),
                ),
              ]),
              if (e.kinds.length > 1) ...[
                const SizedBox(height: 9),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final k in e.kinds.skip(e.kinds.first == e.mainKind ? 1 : 0))
                    if (k != e.mainKind)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: const Color(0xFFF3F6F5), borderRadius: BorderRadius.circular(9)),
                        child: Text(riskLabel(k),
                            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: kSub)),
                      ),
                ]),
              ],
              if (e.text.trim().isNotEmpty) ...[
                const SizedBox(height: 9),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                  decoration: BoxDecoration(color: const Color(0xFFF7FAF9), borderRadius: BorderRadius.circular(13)),
                  child: Text(e.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: kInk, height: 1.35)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
