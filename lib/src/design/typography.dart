import 'package:flutter/material.dart';

import 'tokens.dart';

/// Типографика Inter с отрицательным трекингом — ключевой признак стиля
/// SF Pro Display. Без трекинга текст выглядит «широким» и чужим.
TextTheme buildTextTheme(AppTokens t) {
  TextStyle s(double size, FontWeight weight, double tracking, {Color? color, double? height}) =>
      TextStyle(
        fontFamily: 'Inter',
        fontSize: size,
        fontWeight: weight,
        letterSpacing: tracking,
        height: height,
        color: color ?? t.textPrimary,
      );

  return TextTheme(
    // Крупные суммы и счётчики.
    displayLarge: s(56, FontWeight.w800, -2),
    displayMedium: s(44, FontWeight.w700, -1.6),
    displaySmall: s(34, FontWeight.w700, -1.2),
    // Заголовки экранов.
    headlineLarge: s(32, FontWeight.w700, -1),
    headlineMedium: s(28, FontWeight.w700, -0.8),
    headlineSmall: s(24, FontWeight.w700, -0.6),
    titleLarge: s(20, FontWeight.w700, -0.4),
    titleMedium: s(17, FontWeight.w600, -0.3),
    titleSmall: s(15, FontWeight.w600, -0.2),
    // Текст.
    bodyLarge: s(17, FontWeight.w400, -0.3, height: 1.3),
    bodyMedium: s(15, FontWeight.w400, -0.2),
    bodySmall: s(13, FontWeight.w400, -0.1, color: t.textSecondary),
    // Подписи.
    labelLarge: s(15, FontWeight.w600, -0.2),
    labelMedium: s(13, FontWeight.w600, 0),
    labelSmall: s(11, FontWeight.w600, 0.2),
  );
}
