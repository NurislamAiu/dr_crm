import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Дизайн-система приложения: цвета, градиенты, светлая/тёмная темы.
/// Меняет ТОЛЬКО оформление — на логику не влияет.
class AppColors {
  static const brandStart = Color(0xFF13B7A4); // бирюзовый
  static const brandEnd = Color(0xFF1FBF8F); // зелёный
  static const brand = Color(0xFF13B0A0);

  // Светлая
  static const lightScaffold = Color(0xFFEFF3F2);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightBubbleIn = Color(0xFFFFFFFF);
  static const lightChatTop = Color(0xFFECF3F1);
  static const lightChatBottom = Color(0xFFE6EEF0);
  static const lightTextPrimary = Color(0xFF0F1B22);
  static const lightTextSecondary = Color(0xFF64757F);

  // Тёмная
  static const darkScaffold = Color(0xFF0B141A);
  static const darkSurface = Color(0xFF141F26);
  static const darkCard = Color(0xFF1B2A32);
  static const darkBubbleIn = Color(0xFF1F2C34);
  static const darkChatTop = Color(0xFF0C161C);
  static const darkChatBottom = Color(0xFF0A1216);
  static const darkTextPrimary = Color(0xFFE6ECEF);
  static const darkTextSecondary = Color(0xFF8CA0AB);
}

const brandGradient = LinearGradient(
  colors: [AppColors.brandStart, AppColors.brandEnd],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

/// Приятная градиентная заливка аватара по строке (номеру).
LinearGradient avatarGradient(String seed) {
  const palettes = <List<Color>>[
    [Color(0xFF13B7A4), Color(0xFF1FBF8F)],
    [Color(0xFF6366F1), Color(0xFF8B5CF6)],
    [Color(0xFFF59E0B), Color(0xFFF97316)],
    [Color(0xFF3B82F6), Color(0xFF06B6D4)],
    [Color(0xFFEC4899), Color(0xFFF43F5E)],
    [Color(0xFF10B981), Color(0xFF84CC16)],
    [Color(0xFF8B5CF6), Color(0xFFD946EF)],
  ];
  final idx = seed.isEmpty ? 0 : seed.codeUnits.fold<int>(0, (a, b) => a + b) % palettes.length;
  return LinearGradient(colors: palettes[idx], begin: Alignment.topLeft, end: Alignment.bottomRight);
}

/// Глиф для аватара БЕЗ персональных данных — только KZ или RUS.
/// Казахстан = +7 7xx (начинается с 77); все остальные номера — RUS.
/// Фото пациента не используется по требованиям приватности.
String avatarGlyph(String label) {
  final digits = label.replaceAll(RegExp(r'\D'), '');
  return digits.startsWith('77') ? 'KZ' : 'RUS';
}

/// Фон экрана чата (мягкий градиент).
LinearGradient chatBackground(Brightness b) => b == Brightness.dark
    ? const LinearGradient(colors: [AppColors.darkChatTop, AppColors.darkChatBottom], begin: Alignment.topCenter, end: Alignment.bottomCenter)
    : const LinearGradient(colors: [AppColors.lightChatTop, AppColors.lightChatBottom], begin: Alignment.topCenter, end: Alignment.bottomCenter);

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.brand,
    brightness: brightness,
  ).copyWith(
    surface: dark ? AppColors.darkSurface : AppColors.lightSurface,
    primary: AppColors.brand,
  );

  final scaffold = dark ? AppColors.darkScaffold : AppColors.lightScaffold;
  final textPrimary = dark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary;
  final textSecondary = dark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

  final base = ThemeData(brightness: brightness, useMaterial3: true, colorScheme: scheme);

  return base.copyWith(
    scaffoldBackgroundColor: scaffold,
    textTheme: base.textTheme
        .apply(bodyColor: textPrimary, displayColor: textPrimary)
        .copyWith(
          titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
          titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.3),
        ),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? AppColors.darkSurface : AppColors.lightSurface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3),
      systemOverlayStyle: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    cardTheme: CardThemeData(
      color: dark ? AppColors.darkCard : AppColors.lightSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    dividerTheme: DividerThemeData(color: textSecondary.withValues(alpha: 0.12), thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? AppColors.darkCard : const Color(0xFFF1F4F5),
      hintStyle: TextStyle(color: textSecondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppColors.brand, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        side: BorderSide(color: textSecondary.withValues(alpha: 0.3)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    listTileTheme: const ListTileThemeData(iconColor: AppColors.brand),
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors(textSecondary: textSecondary, bubbleIn: dark ? AppColors.darkBubbleIn : AppColors.lightBubbleIn),
    ],
  );
}

/// Доп. цвета, недоступные в стандартном ColorScheme.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({required this.textSecondary, required this.bubbleIn});
  final Color textSecondary;
  final Color bubbleIn;

  @override
  AppSemanticColors copyWith({Color? textSecondary, Color? bubbleIn}) =>
      AppSemanticColors(textSecondary: textSecondary ?? this.textSecondary, bubbleIn: bubbleIn ?? this.bubbleIn);

  @override
  AppSemanticColors lerp(AppSemanticColors? other, double t) {
    if (other == null) return this;
    return AppSemanticColors(
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      bubbleIn: Color.lerp(bubbleIn, other.bubbleIn, t)!,
    );
  }
}

extension AppThemeX on BuildContext {
  AppSemanticColors get semantic => Theme.of(this).extension<AppSemanticColors>()!;
}
