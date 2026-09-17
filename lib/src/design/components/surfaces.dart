import 'dart:ui';

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'press_scale.dart';

/// Карточка: сквиркл, мягкая тень (только в светлой теме), опциональный
/// градиент и нажатие со scale.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSpace.md),
    this.radius = AppRadius.md,
    this.gradient,
    this.color,
    this.elevated = false,
    this.border = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final double radius;
  final Gradient? gradient;
  final Color? color;

  /// Более выраженная тень (для «поднятых» карточек в светлой теме).
  final bool elevated;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final shape = squircle(
      radius,
      side: border ? BorderSide(color: t.separator, width: 0.5) : BorderSide.none,
    );

    final card = DecoratedBox(
      decoration: ShapeDecoration(
        color: gradient == null ? (color ?? t.card) : null,
        gradient: gradient,
        shape: shape,
        shadows: elevated ? t.shadow : t.shadowSoft,
      ),
      // ShapeDecoration красит фон по форме, но детей НЕ обрезает — клипуем
      // сами, иначе картинки и блики вылезут за сквиркл.
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: Padding(padding: padding, child: child),
      ),
    );

    return onTap == null ? card : PressScale(onTap: onTap, child: card);
  }
}

/// Стеклянная поверхность: размытие + полупрозрачная подложка + hairline.
/// Ею собраны таб-бар, закреплённые шапки и всплывающие панели.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = AppRadius.lg,
    this.blur = 28,
    this.opacity,
    this.border = true,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double radius;
  final double blur;
  final double? opacity;
  final bool border;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final shape = squircle(radius);
    final base = t.isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final alpha = opacity ?? (t.isDark ? 0.72 : 0.78);

    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: base.withValues(alpha: alpha),
            shape: squircle(
              radius,
              side: border
                  ? BorderSide(
                      color: t.isDark ? Colors.white.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.55),
                      width: 0.5,
                    )
                  : BorderSide.none,
            ),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Три размытых цветных пятна вверху экрана — «аврора».
/// Рисуется под контентом и даёт глубину без картинок.
class AuroraBackdrop extends StatelessWidget {
  const AuroraBackdrop({super.key, this.height = 320});

  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _AuroraPainter(
            a: t.accentStart,
            b: t.accentEnd,
            c: t.isDark ? t.accentEnd : t.accentStart,
            opacity: t.isDark ? 0.30 : 0.20,
          ),
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  const _AuroraPainter({required this.a, required this.b, required this.c, required this.opacity});

  final Color a;
  final Color b;
  final Color c;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    void blob(Offset center, double radius, Color color) {
      final p = Paint()
        ..color = color.withValues(alpha: opacity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.9);
      canvas.drawCircle(center, radius, p);
    }

    blob(Offset(size.width * 0.18, size.height * 0.18), size.width * 0.30, a);
    blob(Offset(size.width * 0.82, size.height * 0.10), size.width * 0.26, b);
    blob(Offset(size.width * 0.60, size.height * 0.42), size.width * 0.24, c);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.a != a || old.b != b || old.c != c || old.opacity != opacity;
}
