import 'package:flutter/material.dart';

/// Дизайн-система в духе iOS 26 (Liquid Glass).
///
/// Виджеты НЕ должны знать про Brightness: всё берётся из токенов через
/// `context.tokens`. Акцент — всегда градиент из двух цветов, а не один цвет,
/// поэтому сменные «скины» перекрашивают приложение целиком.

// ── Скины акцента ─────────────────────────────────────────────────────────

enum AppSkin { ocean, sunset, mint, grape, midnight, graphite }

extension AppSkinX on AppSkin {
  String get label => switch (this) {
        AppSkin.ocean => 'Ocean',
        AppSkin.sunset => 'Sunset',
        AppSkin.mint => 'Mint',
        AppSkin.grape => 'Grape',
        AppSkin.midnight => 'Midnight',
        AppSkin.graphite => 'Graphite',
      };

  /// Пара цветов акцента: начало → конец градиента.
  (Color, Color) get colors => switch (this) {
        AppSkin.ocean => (const Color(0xFF0A84FF), const Color(0xFF5E5CE6)),
        AppSkin.sunset => (const Color(0xFFFF9F0A), const Color(0xFFFF375F)),
        AppSkin.mint => (const Color(0xFF30D158), const Color(0xFF40C8E0)),
        AppSkin.grape => (const Color(0xFFBF5AF2), const Color(0xFFFF2D55)),
        AppSkin.midnight => (const Color(0xFF0B3D91), const Color(0xFF64D2FF)),
        AppSkin.graphite => (const Color(0xFF3A3A3C), const Color(0xFF6E6E73)),
      };
}

// ── Радиусы, отступы, длительности ───────────────────────────────────────

/// Радиусы сквиркла. Обычные скругления не используем — силуэт выдаёт не-Apple.
abstract final class AppRadius {
  static const double xs = 10;
  static const double sm = 14;
  static const double md = 20;
  static const double lg = 26;
  static const double xl = 34;
}

abstract final class AppSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;

  /// Горизонтальные поля экрана.
  static const EdgeInsets screen = EdgeInsets.symmetric(horizontal: md);
}

abstract final class AppDuration {
  static const fast = Duration(milliseconds: 180);
  static const medium = Duration(milliseconds: 320);
  static const slow = Duration(milliseconds: 600);
  static const counter = Duration(milliseconds: 900);
  static const chart = Duration(milliseconds: 850);

  /// Нажатие: вжатие быстрее, возврат мягче.
  static const pressDown = Duration(milliseconds: 120);
  static const pressUp = Duration(milliseconds: 220);
}

abstract final class AppCurves {
  /// Основная кривая Apple-подобного движения.
  static const main = Cubic(0.2, 0, 0, 1);
  static const secondary = Curves.easeOutCubic;
  static const spring = Curves.elasticOut;
}

/// Сквиркл заданного радиуса. Один вход для карточек, кнопок, полей, листов.
RoundedSuperellipseBorder squircle(double radius, {BorderSide side = BorderSide.none}) =>
    RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius), side: side);

/// Сквиркл со скруглением только сверху — для модальных листов.
RoundedSuperellipseBorder squircleTop(double radius) => RoundedSuperellipseBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
    );

// ── Токены темы ───────────────────────────────────────────────────────────

@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.skin,
    required this.surface,
    required this.card,
    required this.cardElevated,
    required this.separator,
    required this.fill,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.success,
    required this.danger,
    required this.warning,
    required this.accentStart,
    required this.accentEnd,
    required this.shadow,
    required this.shadowSoft,
    required this.isDark,
  });

  final AppSkin skin;
  final Color surface;
  final Color card;
  final Color cardElevated;
  final Color separator;
  final Color fill;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color success;
  final Color danger;
  final Color warning;
  final Color accentStart;
  final Color accentEnd;

  /// Тени только в светлой теме: в тёмной списки пустые.
  final List<BoxShadow> shadow;
  final List<BoxShadow> shadowSoft;
  final bool isDark;

  /// Градиент акцента — для кнопок, индикаторов, колец.
  LinearGradient get accent => LinearGradient(
        colors: [accentStart, accentEnd],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  /// Один цвет акцента там, где градиент неприменим (иконка, курсор).
  Color get accentSolid => Color.lerp(accentStart, accentEnd, 0.5)!;

  /// Свечение под кнопкой: цвет акцента, мягко растёкшийся вниз.
  List<BoxShadow> get accentGlow => [
        BoxShadow(
          color: accentSolid.withValues(alpha: isDark ? 0.34 : 0.28),
          blurRadius: 22,
          offset: const Offset(0, 10),
        ),
      ];

  static AppTokens light(AppSkin skin) {
    final (a, b) = skin.colors;
    return AppTokens(
      skin: skin,
      surface: const Color(0xFFF2F2F7),
      card: const Color(0xFFFFFFFF),
      cardElevated: const Color(0xFFFFFFFF),
      separator: const Color(0x293C3C43), // #3C3C43 @ 16%
      fill: const Color(0x1F787880), // #787880 @ 12%
      textPrimary: const Color(0xFF000000),
      textSecondary: const Color(0x9E3C3C43), // @ 62%
      textTertiary: const Color(0x523C3C43), // @ 32%
      success: const Color(0xFF34C759),
      danger: const Color(0xFFFF3B30),
      warning: const Color(0xFFFF9500),
      accentStart: a,
      accentEnd: b,
      shadow: const [
        BoxShadow(color: Color(0x1A1C1C2E), blurRadius: 24, offset: Offset(0, 10)),
      ],
      shadowSoft: const [
        BoxShadow(color: Color(0x0D1C1C2E), blurRadius: 12, offset: Offset(0, 4)),
      ],
      isDark: false,
    );
  }

  static AppTokens dark(AppSkin skin) {
    final (a, b) = skin.colors;
    return AppTokens(
      skin: skin,
      surface: const Color(0xFF000000), // истинно чёрный
      card: const Color(0xFF1C1C1E),
      cardElevated: const Color(0xFF2C2C2E),
      separator: const Color(0xFF38383A),
      fill: const Color(0xFF2C2C2E),
      textPrimary: const Color(0xFFFFFFFF),
      textSecondary: const Color(0x9EEBEBF5), // @ 62%
      textTertiary: const Color(0x52EBEBF5), // @ 32%
      success: const Color(0xFF32D74B),
      danger: const Color(0xFFFF453A),
      warning: const Color(0xFFFF9F0A),
      accentStart: a,
      accentEnd: b,
      shadow: const [], // в тёмной теме теней нет
      shadowSoft: const [],
      isDark: true,
    );
  }

  @override
  AppTokens copyWith({AppSkin? skin}) => skin == null || skin == this.skin
      ? this
      : (isDark ? AppTokens.dark(skin) : AppTokens.light(skin));

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      skin: t < 0.5 ? skin : other.skin,
      surface: Color.lerp(surface, other.surface, t)!,
      card: Color.lerp(card, other.card, t)!,
      cardElevated: Color.lerp(cardElevated, other.cardElevated, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      fill: Color.lerp(fill, other.fill, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      accentStart: Color.lerp(accentStart, other.accentStart, t)!,
      accentEnd: Color.lerp(accentEnd, other.accentEnd, t)!,
      shadow: t < 0.5 ? shadow : other.shadow,
      shadowSoft: t < 0.5 ? shadowSoft : other.shadowSoft,
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }
}

extension AppTokensX on BuildContext {
  /// Токены текущей темы. Fallback — светлая: тема всегда их регистрирует,
  /// но так виджет не падает в изолированных тестах.
  AppTokens get tokens => Theme.of(this).extension<AppTokens>() ?? AppTokens.light(AppSkin.ocean);
}
