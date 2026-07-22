import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/app_theme.dart';

/// Метка дня: Сегодня / Вчера / дата.
String dayLabel(DateTime? d) {
  if (d == null) return 'Без даты';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  return DateFormat('dd.MM.yyyy').format(d);
}

/// Разбивка списка на строки: заголовок-день (String) + элементы (T).
/// Список должен быть уже отсортирован по дате (новые сверху).
List<Object> groupByDay<T>(List<T> items, DateTime? Function(T) dateOf) {
  final rows = <Object>[];
  String? current;
  for (final it in items) {
    final key = dayLabel(dateOf(it));
    if (key != current) {
      current = key;
      rows.add(key);
    }
    rows.add(it as Object);
  }
  return rows;
}

/// Заголовок дня в списке.
Widget dayHeader(String label, {int count = 0}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
    child: Row(children: [
      Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.brand)),
      const SizedBox(width: 8),
      if (count > 0)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(color: AppColors.brand.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Text('$count', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.brand)),
        ),
      const Expanded(child: Divider(indent: 10)),
    ]),
  );
}
