import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart' show AppSemanticColors;
import 'tokens.dart';
import 'typography.dart';

/// Сборка темы под iOS-вид: сквиркл-формы, Inter, без Material-ряби,
/// Cupertino-переходы на всех платформах.
ThemeData buildIosTheme(Brightness brightness, AppSkin skin) {
  final t = brightness == Brightness.dark ? AppTokens.dark(skin) : AppTokens.light(skin);
  final text = buildTextTheme(t);

  final scheme = ColorScheme.fromSeed(
    seedColor: t.accentSolid,
    brightness: brightness,
  ).copyWith(
    surface: t.surface,
    onSurface: t.textPrimary,
    primary: t.accentSolid,
    error: t.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.surface,
    canvasColor: t.surface,
    fontFamily: 'Inter',
    textTheme: text,
    // AppTokens — новая дизайн-система; AppSemanticColors нужен экранам,
    // которые ещё живут на старой теме (менеджеры, старые чаты): без него
    // context.semantic падал с «Null check operator used on a null value».
    extensions: <ThemeExtension<dynamic>>[
      t,
      AppSemanticColors(
        textSecondary: t.textSecondary,
        bubbleIn: t.isDark ? t.cardElevated : t.card,
      ),
    ],

    // Material-рябь чужеродна: нажатие показывает PressScale.
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    hoverColor: Colors.transparent,

    // Переходы страниц — Cupertino везде, включая Android.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      },
    ),

    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      foregroundColor: t.textPrimary,
      titleTextStyle: text.titleLarge,
    ),

    dividerTheme: DividerThemeData(color: t.separator, thickness: 0.5, space: 0.5),

    // Поля ввода — заливка fill, сквиркл, без рамок.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.fill,
      hintStyle: text.bodyMedium?.copyWith(color: t.textTertiary),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: t.accentSolid, width: 1.5),
      ),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: squircleTop(AppRadius.xl),
      showDragHandle: false,
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: t.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: squircle(AppRadius.md),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium?.copyWith(color: t.textSecondary),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.isDark ? t.cardElevated : const Color(0xFF1C1C1E),
      contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
      shape: squircle(AppRadius.sm),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.accentSolid,
        textStyle: text.titleMedium,
        shape: squircle(AppRadius.xs),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.accentSolid,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 50),
        textStyle: text.titleMedium,
        shape: squircle(AppRadius.sm),
        elevation: 0,
      ),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.success : t.fill,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),

    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: t.accentSolid,
    ),
  );
}
