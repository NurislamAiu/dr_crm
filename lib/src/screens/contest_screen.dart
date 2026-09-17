import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/contest_service.dart';
import '../design/design.dart';
import '../state/providers.dart';

// ── Палитра ────────────────────────────────────────────────────────────────
// Светлый экран с тёплым золотом наград. Никаких полупрозрачных заливок на
// белом — они выцветают; цвета мест плотные, подложки почти белые.
const _bgTop = Color(0xFFFDF7EC);
const _bgBottom = Color(0xFFF2F2F7);
const _card = Color(0xFFFFFFFF);
const _gold = Color(0xFFE0A008);
const _goldDeep = Color(0xFFB77400);
const _goldSoft = Color(0xFFFFF6DF);
const _silver = Color(0xFF8A98AC);
const _bronze = Color(0xFFC0763C);
const _green = Color(0xFF23A35F);
const _ink = Color(0xFF14161C);
const _sub = Color(0xFF6B7385);
const _hair = Color(0xFFE6E3DC);

Color _placeColor(int place) => switch (place) {
      1 => _gold,
      2 => _silver,
      3 => _bronze,
      _ => _sub,
    };

typedef _Row = ({int place, String uid, String name, int count, bool isMe, int goal});

enum _Period { day, week, month }

/// Соревнование менеджеров.
///
/// Один простой принцип: ВЕСЬ рейтинг — единый список сверху вниз, у каждого
/// участника на карточке его место, счёт и путь к ЛИЧНОЙ премии. Командная
/// премия — отдельной полосой над списком. Никакого пьедестала из трёх
/// визуальных систем: раньше призёры, «вы» и остальные рисовались по-разному,
/// и понять картину целиком было нельзя.
///
/// Считается по leads.createdBy, архивные не в счёт.
class ContestScreen extends ConsumerStatefulWidget {
  const ContestScreen({super.key});

  @override
  ConsumerState<ContestScreen> createState() => _ContestScreenState();
}

class _ContestScreenState extends ConsumerState<ContestScreen>
    with TickerProviderStateMixin {
  /// Зачёт: день, неделя или месяц.
  _Period _period = _Period.day;

  /// Какой день показываем в дневном зачёте (стрелками можно уйти назад).
  DateTime _day = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );

  static DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  bool get _isTodaySelected => _day == _today;

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..forward();

  late final AnimationController _shine = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _intro.dispose();
    _shine.dispose();
    super.dispose();
  }

  void _replay() => _intro
    ..reset()
    ..forward();

  void _shiftDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(_today)) return;
    setState(() => _day = next);
    _replay();
  }

  /// Выбор дня списком за 30 дней (свой, не showDatePicker: без
  /// flutter_localizations системный календарь вышел бы на английском).
  /// Рядом с датой — сколько лидов было: сильный день видно сразу.
  Future<void> _pickDay() async {
    final leads = ref.read(leadsListProvider).value ?? const [];
    final counts = <DateTime, int>{};
    for (final l in leads) {
      final t = l.createdAt;
      if (l.archived || t == null) continue;
      final d = DateTime(t.year, t.month, t.day);
      counts[d] = (counts[d] ?? 0) + 1;
    }
    final days = [for (var i = 0; i < 30; i++) _today.subtract(Duration(days: i))];
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text(
                'Выберите день',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink),
              ),
            ),
            for (final d in days)
              ListTile(
                dense: true,
                selected: d == _day,
                title: Text(
                  d == _today ? 'Сегодня · ${_dayLabel(d)}' : _dayLabel(d),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: d == _day ? FontWeight.w800 : FontWeight.w600,
                    color: _ink,
                  ),
                ),
                trailing: Text(
                  '${counts[d] ?? 0}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: (counts[d] ?? 0) > 0 ? _gold : _sub,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, d),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _day = picked);
    _replay();
  }

  /// «2 сентября, ср».
  static String _dayLabel(DateTime d) {
    const months = [
      'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
      'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
    ];
    const wd = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
    return '${d.day} ${months[d.month - 1]}, ${wd[d.weekday - 1]}';
  }

  /// «сентябрь 2026».
  static String _monthLabel() {
    const months = [
      'январь', 'февраль', 'март', 'апрель', 'май', 'июнь',
      'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь',
    ];
    final n = DateTime.now();
    return '${months[n.month - 1]} ${n.year}';
  }

  /// «25–31 августа» — диапазон текущей недели.
  static String _weekLabel() {
    const months = [
      'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
      'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
    ];
    final n = DateTime.now();
    final mon = DateTime(n.year, n.month, n.day).subtract(Duration(days: n.weekday - 1));
    final sun = mon.add(const Duration(days: 6));
    return mon.month == sun.month
        ? '${mon.day}–${sun.day} ${months[sun.month - 1]}'
        : '${mon.day} ${months[mon.month - 1]} – ${sun.day} ${months[sun.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(appConfigProvider);
    final isAdmin = cfg.role == 'admin' || cfg.role == 'administrator';
    final teamGoal = switch (_period) {
      _Period.day => ref.watch(contestGoalProvider).value ?? 50,
      _Period.week => ref.watch(contestWeekGoalProvider).value ?? 300,
      _Period.month => ref.watch(contestMonthGoalProvider).value ?? 1200,
    };
    final board = switch (_period) {
      _Period.day => ref.watch(leadsByManagerOnDayProvider(_day)),
      _Period.week => ref.watch(leadsWeekByManagerProvider),
      _Period.month => ref.watch(leadsMonthByManagerProvider),
    };
    final personal =
        ref.watch(contestPersonalGoalsProvider).value ?? PersonalGoals.def;
    final managers =
        ref.watch(managersProvider).value ?? const <Map<String, dynamic>>[];
    final total = board.fold<int>(0, (s, e) => s + e.value);

    String nameOf(String uid) {
      final short = uid.length > 6 ? uid.substring(0, 6) : uid;
      for (final m in managers) {
        if (m['id'] != uid) continue;
        final name = (m['name'] as String?)?.trim() ?? '';
        return name.isEmpty ? short : name;
      }
      return short;
    }

    // У КАЖДОГО менеджера своя планка — значит, каждый должен быть на экране,
    // даже с нулём: тот, кто ещё не завёл ни одного лида, видит свою пустую
    // полосу, а не отсутствует в списке. Ноли — в конец, по алфавиту.
    final counts = {for (final e in board) e.key: e.value};
    for (final m in managers) {
      final uid = m['id'] as String?;
      if (uid == null || uid.isEmpty || m['isActive'] == false) continue;
      counts.putIfAbsent(uid, () => 0);
    }
    final ordered = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : nameOf(a.key).compareTo(nameOf(b.key));
      });
    final rows = <_Row>[
      for (var i = 0; i < ordered.length; i++)
        (
          place: i + 1,
          uid: ordered[i].key,
          name: nameOf(ordered[i].key),
          count: ordered[i].value,
          isMe: ordered[i].key == cfg.userId,
          goal: switch (_period) {
            _Period.day => personal.dailyFor(ordered[i].key),
            _Period.week => personal.weeklyFor(ordered[i].key),
            _Period.month => personal.monthlyFor(ordered[i].key),
          },
        ),
    ];
    final me = rows.where((r) => r.isMe).firstOrNull;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_bgTop, _bgBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            children: [
              // ── Шапка: название, настройки, период и день — всё в двух
              // строках, чтобы рейтинг начинался как можно выше. ──
              Row(
                children: [
                  const Text('🏆', style: TextStyle(fontSize: 26)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Конкурс',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            color: _ink,
                            letterSpacing: -0.5,
                            height: 1.05,
                          ),
                        ),
                        Text(
                          switch (_period) {
                            _Period.week => 'Неделя · ${_weekLabel()}',
                            _Period.month => 'Месяц · ${_monthLabel()}',
                            _Period.day => _isTodaySelected
                                ? 'Сегодня · ${_dayLabel(_day)}'
                                : _dayLabel(_day),
                          },
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: _sub,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isAdmin)
                    PressScale(
                      onTap: () => _openSettings(teamGoal, personal),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: ShapeDecoration(
                          color: _card,
                          shape: squircle(AppRadius.sm,
                              side: const BorderSide(color: _hair)),
                        ),
                        child: const Icon(Icons.tune_rounded, size: 19, color: _ink),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _periodToggle()),
                  if (_period == _Period.day) ...[
                    const SizedBox(width: 8),
                    _dayPager(),
                  ],
                ],
              ),
              const SizedBox(height: 14),

              // ── Командная премия: одна полоса, читается за секунду. ──
              GestureDetector(
                onTap: isAdmin ? () => _editTeamGoal(teamGoal) : null,
                child: _TeamCard(
                  total: total,
                  goal: teamGoal,
                  intro: _intro,
                  shine: _shine,
                ),
              ),
              const SizedBox(height: 16),

              // ── Рейтинг: один список, у каждого — место, счёт и СВОЯ
              // линия премии. ──
              if (rows.isEmpty)
                const _Empty()
              else ...[
                Row(
                  children: [
                    const _SectionTitle('Рейтинг'),
                    const Spacer(),
                    GestureDetector(
                      onTap: isAdmin ? () => _editPersonalDefault(personal) : null,
                      child: Text(
                        isAdmin
                            ? 'личная планка: ${_personalDefault(personal)} · изменить'
                            : 'у каждого — своя планка',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: isAdmin ? _goldDeep : _sub.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                for (var i = 0; i < rows.length; i++)
                  _RankCard(
                    row: rows[i],
                    index: i,
                    intro: _intro,
                    shine: _shine,
                    onLongPress: isAdmin
                        ? () => _editPersonalFor(
                            rows[i].uid, rows[i].name, rows[i].goal)
                        : null,
                  ),
                if (me != null && rows.length > 1) ...[
                  const SizedBox(height: 4),
                  _meLine(me, rows),
                ],
              ],
              const SizedBox(height: 16),
              Text(
                isAdmin
                    ? 'Настройки премий — кнопкой вверху. Долгое нажатие на менеджера — его личная планка.'
                    : 'Командная премия — общая цель. Личная — планка на карточке: добил её — премия твоя.',
                style: const TextStyle(fontSize: 12, color: _sub, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Строка под рейтингом: где я и что мне осталось. Одна фраза, без
  /// отдельной карточки — карточка «вы» и так подсвечена в списке.
  Widget _meLine(_Row me, List<_Row> rows) {
    final above = rows.where((r) => r.place == me.place - 1).firstOrNull;
    final parts = <String>[
      if (above == null)
        'Вы ведёте гонку'
      else if (above.count - me.count <= 0)
        'Ещё один лид — и вы обойдёте ${above.name}'
      else
        'До ${above.name} — ${above.count - me.count} ${_leadWord(above.count - me.count)}',
      if (me.count < me.goal)
        'до личной премии — ${me.goal - me.count}'
      else
        'личная премия взята 🏅',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        parts.join(' · '),
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: _goldDeep,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _periodToggle() {
    Widget seg(String label, _Period p) {
      final sel = p == _period;
      return Expanded(
        child: GestureDetector(
          onTap: () {
            if (sel) return;
            setState(() => _period = p);
            _replay();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: ShapeDecoration(
              color: sel ? _ink : Colors.transparent,
              shape: squircle(10),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: sel ? Colors.white : _sub,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(
        color: _card,
        shape: squircle(12, side: const BorderSide(color: _hair)),
      ),
      child: Row(children: [seg('День', _Period.day), seg('Неделя', _Period.week), seg('Месяц', _Period.month)]),
    );
  }

  Widget _dayPager() {
    Widget arrow(IconData icon, VoidCallback? onTap) => Opacity(
          opacity: onTap == null ? 0.25 : 1,
          child: PressScale(
            onTap: onTap ?? () {},
            child: SizedBox(
              width: 30,
              height: 36,
              child: Icon(icon, size: 19, color: _ink),
            ),
          ),
        );
    return Container(
      decoration: ShapeDecoration(
        color: _card,
        shape: squircle(12, side: const BorderSide(color: _hair)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          arrow(Icons.chevron_left_rounded, () => _shiftDay(-1)),
          PressScale(
            onTap: _pickDay,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Icon(Icons.calendar_month_rounded, size: 17, color: _ink),
            ),
          ),
          arrow(Icons.chevron_right_rounded,
              _isTodaySelected ? null : () => _shiftDay(1)),
        ],
      ),
    );
  }

  /// Меню настроек премий: два независимых пункта. Раньше оба поля жили в
  /// одном окне и читались как одна настройка — владелец просил развести.
  Future<void> _openSettings(int teamGoal, PersonalGoals personal) async {
    final period = switch (_period) { _Period.day => 'за день', _Period.week => 'за неделю', _Period.month => 'за месяц' };
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Настройки премий',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: _ink),
                ),
              ),
            ),
            ListTile(
              leading: const Text('🏆', style: TextStyle(fontSize: 22)),
              title: const Text('Командная премия',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _ink)),
              subtitle: Text('вся команда набирает $teamGoal лидов $period',
                  style: const TextStyle(fontSize: 12.5, color: _sub)),
              trailing: const Icon(Icons.chevron_right_rounded, color: _sub),
              onTap: () {
                Navigator.pop(ctx);
                _editTeamGoal(teamGoal);
              },
            ),
            ListTile(
              leading: const Text('🏅', style: TextStyle(fontSize: 22)),
              title: const Text('Личная премия',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _ink)),
              subtitle: Text(
                  'планка каждому: ${_personalDefault(personal)} лидов $period · индивидуально — долгим нажатием на менеджера',
                  style: const TextStyle(fontSize: 12.5, color: _sub)),
              trailing: const Icon(Icons.chevron_right_rounded, color: _sub),
              onTap: () {
                Navigator.pop(ctx);
                _editPersonalDefault(personal);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  /// Одно число: сколько лидов должна набрать ВСЯ команда.
  Future<void> _editTeamGoal(int current) async {
    final value = await _askNumber(
      title: switch (_period) {
        _Period.day => 'Командная премия за день',
        _Period.week => 'Командная премия за неделю',
        _Period.month => 'Командная премия за месяц',
      },
      hint: switch (_period) {
        _Period.day => 'Сколько лидов команда набирает за день, чтобы получить премию.',
        _Period.week => 'Сколько лидов команда набирает с понедельника по воскресенье, чтобы получить премию.',
        _Period.month => 'Сколько лидов команда набирает с 1-го числа до конца месяца, чтобы получить премию.',
      },
      label: 'Лидов на команду',
      initial: current,
    );
    if (value == null) return;
    try {
      final svc = ref.read(contestServiceProvider);
      await switch (_period) {
        _Period.day => svc.setGoal(value),
        _Period.week => svc.setWeekGoal(value),
        _Period.month => svc.setMonthGoal(value),
      };
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось сохранить: $e')));
      }
    }
  }

  /// Одно число: общая личная планка каждому менеджеру.
  Future<void> _editPersonalDefault(PersonalGoals personal) async {
    final per = switch (_period) { _Period.day => 'день', _Period.week => 'неделю', _Period.month => 'месяц' };
    final value = await _askNumber(
      title: 'Личная премия за $per',
      hint: 'Сколько лидов за $per даёт менеджеру личную премию. Это планка по умолчанию — отдельному менеджеру её можно поменять долгим нажатием на его карточку.',
      label: 'Лидов на менеджера',
      initial: _personalDefault(personal),
    );
    if (value == null) return;
    try {
      await ref.read(contestServiceProvider).setPersonalDefaults(
            daily: _period == _Period.day ? value : null,
            weekly: _period == _Period.week ? value : null,
            monthly: _period == _Period.month ? value : null,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось сохранить: $e')));
      }
    }
  }

  int _personalDefault(PersonalGoals p) => switch (_period) {
        _Period.day => p.daily,
        _Period.week => p.weekly,
        _Period.month => p.monthly,
      };

  /// Общее окно «введите число» для обеих настроек.
  Future<int?> _askNumber({
    required String title,
    required String hint,
    required String label,
    required int initial,
  }) async {
    final ctrl = TextEditingController(text: '$initial');
    final value = await showDialog<int>(
      context: context,
      builder: (d) => AlertDialog(
        shape: squircle(AppRadius.lg),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hint, style: const TextStyle(fontSize: 13.5, height: 1.35)),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(d, int.tryParse(ctrl.text.trim())),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    return value != null && value >= 1 ? value : null;
  }

  /// Индивидуальная планка одного менеджера (долгое нажатие на его карточку).
  Future<void> _editPersonalFor(String uid, String name, int current) async {
    final ctrl = TextEditingController(text: '$current');
    final result = await showDialog<({int? value, bool reset})>(
      context: context,
      builder: (d) => AlertDialog(
        shape: squircle(AppRadius.lg),
        title: Text('Личная планка · $name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Сколько лидов за ${switch (_period) { _Period.day => 'день', _Period.week => 'неделю', _Period.month => 'месяц' }} даёт $name личную премию. «Как у всех» — общая планка.',
              style: const TextStyle(fontSize: 13.5, height: 1.35),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Лидов до премии',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, (value: null, reset: true)),
            child: const Text('Как у всех'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(
                d, (value: int.tryParse(ctrl.text.trim()), reset: false)),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (result == null) return;
    try {
      final svc = ref.read(contestServiceProvider);
      if (result.reset) {
        await svc.setPersonalFor(uid);
      } else if (result.value != null && result.value! >= 1) {
        await svc.setPersonalFor(
          uid,
          daily: _period == _Period.day ? result.value : null,
          weekly: _period == _Period.week ? result.value : null,
          monthly: _period == _Period.month ? result.value : null,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось сохранить: $e')));
      }
    }
  }
}

String _leadWord(int n) {
  final t = n % 100;
  if (t >= 11 && t <= 14) return 'лидов';
  return switch (n % 10) {
    1 => 'лид',
    2 || 3 || 4 => 'лида',
    _ => 'лидов',
  };
}

// ── Командная премия ───────────────────────────────────────────────────────
class _TeamCard extends StatelessWidget {
  const _TeamCard({
    required this.total,
    required this.goal,
    required this.intro,
    required this.shine,
  });
  final int total;
  final int goal;
  final Animation<double> intro;
  final Animation<double> shine;

  @override
  Widget build(BuildContext context) {
    final reached = total >= goal;
    final left = goal - total;
    final target = goal == 0 ? 0.0 : (total / goal).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          colors: reached
              ? [_goldDeep.withValues(alpha: 0.28), _gold.withValues(alpha: 0.10)]
              : [_card, _card],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: squircle(
          AppRadius.md,
          side: BorderSide(color: reached ? _gold : _hair, width: reached ? 1.4 : 1),
        ),
        shadows: [
          BoxShadow(
            color: (reached ? _gold : const Color(0xFF14161C))
                .withValues(alpha: reached ? 0.20 : 0.06),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'КОМАНДНАЯ ПРЕМИЯ',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                  color: reached ? _goldDeep : _sub,
                ),
              ),
              const Spacer(),
              if (reached)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: ShapeDecoration(color: _gold, shape: squircle(8)),
                  child: const Text(
                    '🏆 ЕСТЬ!',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF3D2A00),
                    ),
                  ),
                )
              else
                Text(
                  'осталось $left',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w800, color: _sub),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _Counter(
                value: total,
                intro: intro,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: _ink,
                  height: 1,
                  letterSpacing: -1,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 3, left: 6),
                child: Text(
                  'из $goal лидов',
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700, color: _sub),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AnimatedBuilder(
            animation: Listenable.merge([intro, shine]),
            builder: (context, _) {
              final v = target * Curves.easeOutCubic.transform(intro.value);
              return ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: SizedBox(
                  height: 10,
                  child: Stack(
                    children: [
                      Container(color: const Color(0xFFEDEAE3)),
                      // ВАЖНО: заполнение прижато Positioned'ом, а не голым
                      // FractionallySizedBox: свободный DecoratedBox без
                      // ребёнка в Stack получает нулевую высоту, и полоса
                      // выглядела пустой при почти закрытой цели.
                      Positioned.fill(
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: v.clamp(0.0, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                  colors: [_goldDeep, _gold]),
                              boxShadow: [
                                BoxShadow(
                                    color: _gold.withValues(alpha: 0.45),
                                    blurRadius: 10),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (reached) _ShineSweep(t: shine.value),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Бегущий блик поверх заполненной полосы.
class _ShineSweep extends StatelessWidget {
  const _ShineSweep({required this.t});
  final double t;

  @override
  Widget build(BuildContext context) {
    final x = -1.4 + t * 2.8;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(x - 0.35, 0),
            end: Alignment(x + 0.35, 0),
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.55),
              Colors.white.withValues(alpha: 0),
            ],
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ── Карточка участника ─────────────────────────────────────────────────────
class _RankCard extends StatelessWidget {
  const _RankCard({
    required this.row,
    required this.index,
    required this.intro,
    required this.shine,
    this.onLongPress,
  });
  final _Row row;
  final int index;
  final Animation<double> intro;
  final Animation<double> shine;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final leader = row.place == 1;
    final color = _placeColor(row.place);
    final done = row.count >= row.goal;
    final left = row.goal - row.count;
    final progress = row.goal == 0 ? 0.0 : (row.count / row.goal).clamp(0.0, 1.0);

    return AnimatedBuilder(
      animation: Listenable.merge([intro, shine]),
      builder: (context, child) {
        // Всё, что зависит от анимации, считается ВНУТРИ builder — вынесенное
        // наружу замирает и карточки остаются невидимыми.
        final p = ((intro.value - index * 0.07) / (1 - index * 0.07)).clamp(0.0, 1.0);
        final t = Curves.easeOutCubic.transform(p);
        final glow = leader ? 0.30 + 0.20 * (0.5 + 0.5 * (shine.value * 2 - 1)) : 0.0;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 16),
            child: GestureDetector(
              onLongPress: onLongPress,
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
                decoration: ShapeDecoration(
                  color: row.isMe ? _goldSoft : _card,
                  shape: squircle(
                    AppRadius.md,
                    side: leader
                        ? const BorderSide(color: _gold, width: 1.4)
                        : row.isMe
                            ? BorderSide(color: _gold.withValues(alpha: 0.55), width: 1.1)
                            : const BorderSide(color: _hair),
                  ),
                  shadows: [
                    BoxShadow(
                      color: leader
                          ? _gold.withValues(alpha: glow)
                          : const Color(0x0F14161C),
                      blurRadius: leader ? 18 : 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: child,
              ),
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Строка 1: место, имя, счёт «7 / 10» ──
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: row.place <= 3 ? color : _sub.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '${row.place}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: row.place <= 3 ? Colors.white : _sub,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              _Avatar(name: row.name, color: color, big: leader),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    if (leader)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Text('👑', style: TextStyle(fontSize: 14)),
                      ),
                    Flexible(
                      child: Text(
                        row.isMe ? '${row.name} · вы' : row.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: leader ? 16 : 15,
                          fontWeight: FontWeight.w800,
                          color: row.isMe ? _goldDeep : _ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Счёт и планка рядом: «7 / 10» читается как одно число.
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _Counter(
                    value: row.count,
                    intro: intro,
                    style: TextStyle(
                      fontSize: leader ? 28 : 24,
                      fontWeight: FontWeight.w900,
                      color: done ? _goldDeep : _ink,
                      height: 1,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2, left: 3),
                    child: Text(
                      '/ ${row.goal}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _sub,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 11),
          // ── Строка 2: ЛИЧНАЯ ПЛАНКА — толстая полоса до своей цели. ──
          AnimatedBuilder(
            animation: intro,
            builder: (context, _) {
              final v = (progress * Curves.easeOutCubic.transform(intro.value)).clamp(0.0, 1.0);
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 14,
                  child: Stack(
                    children: [
                      Container(color: const Color(0xFFEDEAE3)),
                      Positioned.fill(
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: v,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: done
                                    ? const [_goldDeep, _gold]
                                    : [_green.withValues(alpha: 0.8), _green],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: (done ? _gold : _green).withValues(alpha: 0.35),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Процент внутри полосы, когда есть куда его вписать.
                      if (v > 0.22)
                        Positioned.fill(
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: v,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Text(
                                  '${(progress * 100).round()}%',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 7),
          // ── Строка 3: словами — что осталось до личной премии. ──
          Row(
            children: [
              Expanded(
                child: Text(
                  done
                      ? '🏅 Личная премия взята'
                      : 'До личной премии — $left ${_leadWord(left)}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: done ? _goldDeep : _sub,
                  ),
                ),
              ),
              Text(
                'планка ${row.goal}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _sub.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Круглый аватар с первой буквой имени.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.color, this.big = false});
  final String name;
  final Color color;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final size = big ? 46.0 : 38.0;
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.9), color.withValues(alpha: 0.55)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          fontSize: big ? 19 : 16,
          fontWeight: FontWeight.w900,
          color: Colors.white,
        ),
      ),
    );
  }
}

// ── Мелочи ────────────────────────────────────────────────────────────────

/// Число, которое «набегает» при появлении экрана.
class _Counter extends StatelessWidget {
  const _Counter({required this.value, required this.intro, required this.style});
  final int value;
  final Animation<double> intro;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: intro,
      builder: (context, _) {
        final v = (value * Curves.easeOutCubic.transform(intro.value)).round();
        return Text('$v', style: style);
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: _sub,
          letterSpacing: 1.1,
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            const Text('🏁', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 12),
            const Text(
              'Гонка ещё не началась',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: _ink),
            ),
            const SizedBox(height: 5),
            Text(
              'Первый оформленный лид займёт первое место',
              style: TextStyle(fontSize: 13, color: _sub.withValues(alpha: 0.9)),
            ),
          ],
        ),
      );
}
