import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Общие элементы «мягкого» UI для экранов Лиды / VIP:
/// шапка со скруглением, аватар с делением по стране (флаг), недельная лента,
/// стат-карточки. Иконки — Iconsax.

const kTeal = Color(0xFF12B0A1);
const kTealDeep = Color(0xFF0C8577);
const kInk = Color(0xFF10332C);
// Вторичный текст: ≥4.5:1 на белом (WCAG), тёплый тил-серый.
const kSub = Color(0xFF5C736C);
const kAmber = Color(0xFFEF9F27);
const kAmberDeep = Color(0xFF8F5C06);

/// Казахстан = номер после +7 начинается с 7 (цифры «77…»); иначе — Россия.
bool phoneIsKz(String? phone) =>
    (phone ?? '').replaceAll(RegExp(r'\D'), '').startsWith('77');

String flagFor(String? phone) => phoneIsKz(phone) ? 'assets/kz.png' : 'assets/rus.png';

/// Красивое разделение тысяч: 1850000 → «1 850 000».
String money(num v) {
  final s = v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
  final parts = s.split('.');
  final intPart = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]} ');
  return parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
}

/// Валюты предоплаты.
const kKzt = 'KZT';
const kRub = 'RUB';

/// Символ валюты: ₸ / ₽ (по умолчанию тенге).
String currencySymbol(String? c) => c == kRub ? '₽' : '₸';

/// Валюта по номеру: российский номер → рубли, иначе тенге.
String defaultCurrency(String? phone) => phoneIsKz(phone) ? kKzt : kRub;

/// «50000» + KZT → «50 000 ₸».
String moneyWith(num v, String? currency) => '${money(v)} ${currencySymbol(currency)}';

/// Скопировать номер в буфер + подтверждение (долгое нажатие по номеру).
Future<void> copyPhone(BuildContext context, String? phone) async {
  final raw = (phone ?? '').trim();
  if (raw.isEmpty) return;
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  final value = digits.length == 11 ? '+$digits' : raw;
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  HapticFeedback.selectionClick();
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text('Номер скопирован: ${formatPhone(value)}'),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
}

/// Имя для показа: если это просто телефон (цифры) — красиво форматируем.
String displayName(String name) {
  final digits = name.replaceAll(RegExp(r'\D'), '');
  final nonPhoneChars = name.replaceAll(RegExp(r'[\d\s+\-()]'), '');
  if (nonPhoneChars.isEmpty && digits.length == 11) return formatPhone(name);
  return name;
}

/// «77473193061» → «+7 747 319-30-61»; чужие форматы возвращаются как есть.
String formatPhone(String? raw) {
  final d = (raw ?? '').replaceAll(RegExp(r'\D'), '');
  if (d.length == 11 && (d.startsWith('7') || d.startsWith('8'))) {
    final n = d.startsWith('8') ? '7${d.substring(1)}' : d;
    return '+7 ${n.substring(1, 4)} ${n.substring(4, 7)}-${n.substring(7, 9)}-${n.substring(9)}';
  }
  return raw ?? '';
}

/// Аватар клиента: скруглённая плитка, полностью залитая флагом страны.
class CountryAvatar extends StatelessWidget {
  const CountryAvatar({super.key, required this.phone, required this.name, this.size = 50});
  final String? phone;
  final String name; // оставлено в API на будущее (тултипы и т.п.)
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        // Тонкая обводка: у флага РФ верхняя полоса белая — без неё сливается с карточкой.
        border: Border.all(color: Colors.black.withValues(alpha: 0.07)),
        image: DecorationImage(image: AssetImage(flagFor(phone)), fit: BoxFit.cover),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 3))],
      ),
    );
  }
}

/// Кнопка в шапке (полупрозрачная или белая).
class SoftHeaderButton extends StatelessWidget {
  const SoftHeaderButton({super.key, required this.icon, required this.onTap, this.filled = false, this.accent = kTealDeep, this.active = false, this.tooltip});
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;
  final bool active;
  final Color accent;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final bg = filled || active ? Colors.white : Colors.white.withValues(alpha: 0.18);
    final fg = filled || active ? accent : Colors.white;
    final btn = Material(
      color: bg,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: onTap,
        child: SizedBox(width: 44, height: 44, child: Icon(icon, color: fg, size: 21)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Скруглённая шапка-градиент со строкой заголовка, кнопками и (опц.) лентой.
class SoftHeader extends StatelessWidget {
  const SoftHeader({
    super.key,
    required this.color,
    required this.colorDeep,
    required this.title,
    required this.dateLabel,
    required this.actions,
    this.strip,
    this.showBack = false,
  });
  final Color color;
  final Color colorDeep;
  final String title;
  final String dateLabel;
  final List<Widget> actions;
  final Widget? strip;

  /// Кнопка «назад» слева (для экранов, открытых поверх вкладок).
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [color, colorDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
        boxShadow: [BoxShadow(color: colorDeep.withValues(alpha: 0.20), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      padding: EdgeInsets.fromLTRB(20, top + 14, 16, strip != null ? 32 : 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showBack)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: SoftHeaderButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Назад',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dateLabel, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12.5)),
                    const SizedBox(height: 3),
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 7),
                  actions[i],
                ],
              ]),
            ],
          ),
          if (strip != null) ...[const SizedBox(height: 24), strip!],
        ],
      ),
    );
  }
}

/// Недельная лента (пн–вс текущей недели относительно [anchor]).
class WeekStrip extends StatelessWidget {
  const WeekStrip({
    super.key,
    required this.selected,
    required this.daysWithData,
    required this.onTap,
    required this.accent,
  });
  final DateTime? selected;
  final Set<int> daysWithData; // ключи вида y*10000+m*100+d
  final ValueChanged<DateTime> onTap;
  final Color accent;

  static int keyOf(DateTime d) => d.year * 10000 + d.month * 100 + d.day;
  static const _wd = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    // Все 7 дней помещаются в ширину — без скролла и без «плиток»-блоков:
    // фон есть только у выбранного дня, сегодня отмечено тонкой обводкой.
    return Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i < 6 ? 6 : 0),
              child: _day(monday.add(Duration(days: i)), i, now),
            ),
          ),
      ],
    );
  }

  Widget _day(DateTime day, int i, DateTime now) {
    final isSel = selected != null &&
        selected!.year == day.year && selected!.month == day.month && selected!.day == day.day;
    final hasData = daysWithData.contains(keyOf(day));
    final isToday = day.year == now.year && day.month == now.month && day.day == now.day;
    return GestureDetector(
      onTap: () => onTap(day),
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_wd[i], style: TextStyle(fontSize: 10.5, color: Colors.white.withValues(alpha: isSel ? 0.95 : 0.6))),
          const SizedBox(height: 9),
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSel ? Colors.white : Colors.transparent,
              border: !isSel && isToday ? Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1.1) : null,
              boxShadow: isSel
                  ? [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8, offset: const Offset(0, 3))]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text('${day.day}',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: isSel ? accent : Colors.white)),
          ),
          const SizedBox(height: 7),
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hasData ? Colors.white.withValues(alpha: 0.85) : Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }
}

/// Стат-карточка (иконка + число + подпись) на белом листе.
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.value, required this.label, this.accent = kInk, this.icon, this.iconColor, this.flex = 1});
  final String value;
  final String label;
  final Color accent;
  final IconData? icon;
  final Color? iconColor;
  final int flex;

  @override
  Widget build(BuildContext context) {
    final ic = iconColor ?? accent;
    return Expanded(
      flex: flex,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: ic.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(13)),
                child: Icon(icon, size: 19, color: ic),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // FittedBox: длинные суммы ужимаются, а не режутся в «…».
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(value,
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 17.5,
                            fontWeight: FontWeight.w800,
                            color: accent,
                            letterSpacing: -0.3,
                            fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                  const SizedBox(height: 1),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(label, maxLines: 1, style: const TextStyle(fontSize: 11, color: kSub)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Стеклянная стат-карточка для цветной шапки (белый текст на тил/красном).
class HeaderStat extends StatelessWidget {
  const HeaderStat({super.key, required this.value, required this.label, this.valueColor = Colors.white});
  final String value;
  final String label;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // FittedBox: длинные значения ужимаются, а не режутся в «…».
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: valueColor,
                      letterSpacing: -0.3,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            const SizedBox(height: 1),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(label,
                  maxLines: 1,
                  style: TextStyle(fontSize: 10.5, color: Colors.white.withValues(alpha: 0.8))),
            ),
          ],
        ),
      ),
    );
  }
}

/// Заголовок дня внутри списка (для режима «все дни»).
Widget softDayHeader(String label, int count, Color accent) => Padding(
      padding: const EdgeInsets.fromLTRB(6, 16, 6, 8),
      child: Row(children: [
        Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: accent)),
        const SizedBox(width: 7),
        Text('$count', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: kSub)),
        const SizedBox(width: 12),
        Expanded(child: Container(height: 1, color: Colors.black.withValues(alpha: 0.05))),
      ]),
    );

/// Простой выбор времени: сетка готовых слотов (тап — и готово), без
/// циферблата. Внизу — «Ввести вручную» для нестандартного времени.
/// Возвращает TimeOfDay или null (отмена).
Future<TimeOfDay?> showSoftTimePicker(
  BuildContext context, {
  TimeOfDay? selected,
  Color accent = kTealDeep,
  int startHour = 8,
  int endHour = 23,
  int stepMinutes = 15,
}) {
  return showModalBottomSheet<TimeOfDay>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (sheet) {
      final slots = <TimeOfDay>[
        for (var h = startHour; h <= endHour; h++)
          for (var m = 0; m < 60; m += stepMinutes) TimeOfDay(hour: h, minute: m),
      ];
      String two(int v) => v.toString().padLeft(2, '0');

      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Row(children: [
              const Expanded(child: Text('Выберите время', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kInk))),
              if (selected != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                  child: Text('${two(selected.hour)}:${two(selected.minute)}',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: accent)),
                ),
            ]),
          ),
          // Сетка слотов: 4 в ряд, крупные кнопки — промахнуться сложно.
          Flexible(
            child: GridView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.1,
              ),
              itemCount: slots.length,
              itemBuilder: (context, i) {
                final t = slots[i];
                final isSel = selected != null && selected.hour == t.hour && selected.minute == t.minute;
                final isRound = t.minute == 0; // целые часы — заметнее
                return Material(
                  color: isSel ? accent : (isRound ? accent.withValues(alpha: 0.10) : const Color(0xFFF2F4F3)),
                  borderRadius: BorderRadius.circular(13),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(13),
                    onTap: () => Navigator.pop(sheet, t),
                    child: Center(
                      child: Text('${two(t.hour)}:${two(t.minute)}',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: isRound || isSel ? FontWeight.w800 : FontWeight.w500,
                            color: isSel ? Colors.white : (isRound ? accent : kInk),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          )),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: SizedBox(
              width: double.infinity,
              height: 46,
              child: TextButton.icon(
                icon: const Icon(Icons.keyboard_alt_outlined, size: 19),
                label: const Text('Ввести другое время', style: TextStyle(fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(foregroundColor: accent),
                onPressed: () async {
                  final t = await showTimePicker(
                    context: sheet,
                    initialTime: selected ?? const TimeOfDay(hour: 12, minute: 0),
                    // Сразу клавиатура вместо циферблата.
                    initialEntryMode: TimePickerEntryMode.input,
                    builder: (ctx, child) => Theme(
                      data: Theme.of(ctx).copyWith(colorScheme: Theme.of(ctx).colorScheme.copyWith(primary: accent)),
                      child: MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
                    ),
                  );
                  if (t != null && sheet.mounted) Navigator.pop(sheet, t);
                },
              ),
            ),
          ),
        ]),
      );
    },
  );
}

/// Результат «Сбросить фильтр» из [showSoftDatePicker].
const clearDateSentinel = 'clear';

/// Обычный кликабельный календарь: месяц со стрелками, тап по дню — выбор.
/// Точки под днями — там, где есть записи. Возвращает DateTime,
/// [clearDateSentinel] или null (отмена).
Future<Object?> showSoftDatePicker(
  BuildContext context, {
  DateTime? selected,
  Color accent = kTealDeep,
  Set<int> daysWithData = const {},
}) {
  return showModalBottomSheet<Object>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => _SoftCalendar(selected: selected, accent: accent, daysWithData: daysWithData),
  );
}

const _monthsNom = ['', 'Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'];

class _SoftCalendar extends StatefulWidget {
  const _SoftCalendar({required this.selected, required this.accent, required this.daysWithData});
  final DateTime? selected;
  final Color accent;
  final Set<int> daysWithData;

  @override
  State<_SoftCalendar> createState() => _SoftCalendarState();
}

class _SoftCalendarState extends State<_SoftCalendar> {
  late DateTime _month; // первый день показанного месяца

  @override
  void initState() {
    super.initState();
    final base = widget.selected ?? DateTime.now();
    _month = DateTime(base.year, base.month);
  }

  static int _key(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final sel = widget.selected;

    final firstWeekday = _month.weekday; // 1 = пн
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    // Ячейки месяца: пустые до 1-го числа + все дни.
    final cells = <DateTime?>[
      for (var i = 1; i < firstWeekday; i++) null,
      for (var d = 1; d <= daysInMonth; d++) DateTime(_month.year, _month.month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }

    Widget arrow(IconData icon, VoidCallback onTap) => Material(
          color: accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 20, color: accent)),
          ),
        );

    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 10),
        Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3))),
        // Месяц + стрелки.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
          child: Row(children: [
            Expanded(
              child: Text('${_monthsNom[_month.month]} ${_month.year}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kInk, letterSpacing: -0.3)),
            ),
            arrow(Icons.chevron_left_rounded, () => setState(() => _month = DateTime(_month.year, _month.month - 1))),
            const SizedBox(width: 8),
            arrow(Icons.chevron_right_rounded, () => setState(() => _month = DateTime(_month.year, _month.month + 1))),
          ]),
        ),
        // Дни недели.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            for (final w in const ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'])
              Expanded(
                child: Center(child: Text(w, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: kSub))),
              ),
          ]),
        ),
        const SizedBox(height: 6),
        // Сетка дней: тап по дню — выбор.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(children: [
            for (var row = 0; row < cells.length ~/ 7; row++)
              Row(children: [
                for (var col = 0; col < 7; col++)
                  Expanded(child: _dayCell(cells[row * 7 + col], sel, today, accent)),
              ]),
          ]),
        ),
        // Сбросить фильтр.
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: SizedBox(
            width: double.infinity,
            height: 46,
            child: sel != null
                ? TextButton.icon(
                    onPressed: () => Navigator.pop(context, clearDateSentinel),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Сбросить фильтр — показать все дни', style: TextStyle(fontWeight: FontWeight.w700)),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFC6403C)),
                  )
                : TextButton(
                    onPressed: () => Navigator.pop(context, today),
                    style: TextButton.styleFrom(foregroundColor: accent),
                    child: const Text('Сегодня', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _dayCell(DateTime? d, DateTime? sel, DateTime today, Color accent) {
    if (d == null) return const SizedBox(height: 46);
    final isSel = sel != null && sel.year == d.year && sel.month == d.month && sel.day == d.day;
    final isToday = d == today;
    final hasData = widget.daysWithData.contains(_key(d));
    return SizedBox(
      height: 46,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.pop(context, d),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSel ? accent : Colors.transparent,
              border: !isSel && isToday ? Border.all(color: accent, width: 1.3) : null,
            ),
            alignment: Alignment.center,
            child: Text('${d.day}',
                style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: isSel || isToday ? FontWeight.w800 : FontWeight.w500,
                    color: isSel ? Colors.white : kInk)),
          ),
          const SizedBox(height: 1),
          Container(
            width: 4.5,
            height: 4.5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hasData ? (isSel ? accent : accent.withValues(alpha: 0.75)) : Colors.transparent,
            ),
          ),
        ]),
      ),
    );
  }
}

const _months = ['', 'января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
const _weekdaysFull = ['', 'Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'];

/// «5 июля» без зависимости от локали intl.
String dateRu(DateTime d) => '${d.day} ${_months[d.month]}';

/// «Вторник, 22 июля» — для шапки.
String weekdayDateRu(DateTime d) => '${_weekdaysFull[d.weekday]}, ${dateRu(d)}';

String humanDate(DateTime? d) {
  if (d == null) return 'Без даты';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  if (diff == -1) return 'Завтра';
  return dateRu(d);
}

/// Диалог ввода суммы с выбором валюты (₸ / ₽). Контроллер живёт внутри
/// диалога — иначе Flutter падает с «controller was used after being disposed».
/// Возвращает (текст суммы, валюта) или null при отмене.
Future<(String, String)?> showAmountDialog(
  BuildContext context, {
  String initial = '',
  String currency = kKzt,
  String title = 'Предоплата',
  Color accent = kTealDeep,
}) {
  return showDialog<(String, String)>(
    context: context,
    builder: (_) => _AmountDialog(initial: initial, currency: currency, title: title, accent: accent),
  );
}

class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.initial, required this.currency, required this.title, required this.accent});
  final String initial;
  final String currency;
  final String title;
  final Color accent;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);
  late String _cur = widget.currency;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(widget.title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: _c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          onSubmitted: (v) => Navigator.pop(context, (v.trim(), _cur)),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            suffixText: currencySymbol(_cur),
            hintText: '0',
          ),
        ),
        const SizedBox(height: 12),
        CurrencyToggle(value: _cur, accent: widget.accent, onChanged: (v) => setState(() => _cur = v)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: widget.accent),
          onPressed: () => Navigator.pop(context, (_c.text.trim(), _cur)),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// Переключатель валюты: Тенге ₸ / Рубли ₽.
class CurrencyToggle extends StatelessWidget {
  const CurrencyToggle({super.key, required this.value, required this.onChanged, this.accent = kTealDeep});
  final String value;
  final ValueChanged<String> onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    Widget item(String cur, String label) {
      final sel = value == cur;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(cur),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: sel ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
              boxShadow: sel
                  ? [BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 8, offset: const Offset(0, 2))]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: sel ? FontWeight.w800 : FontWeight.w500,
                    color: sel ? accent : kSub)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: const Color(0xFFEFF4F2), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [item(kKzt, 'Тенге ₸'), item(kRub, 'Рубли ₽')]),
    );
  }
}
