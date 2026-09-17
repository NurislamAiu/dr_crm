import 'package:flutter/material.dart';

import '../tokens.dart';
import 'press_scale.dart';

/// Главная кнопка: высота 54, градиент акцента и свечение его же цветом.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.busy = false,
    this.expand = true,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool expand;

  /// Разрушающее действие — красный вместо акцента, без свечения.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final enabled = onPressed != null && !busy;
    final gradient = danger
        ? LinearGradient(colors: [t.danger, t.danger])
        : t.accent;

    return PressScale(
      onTap: enabled ? onPressed : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Container(
          height: 54,
          width: expand ? double.infinity : null,
          padding: expand ? null : const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          decoration: ShapeDecoration(
            gradient: gradient,
            shape: squircle(AppRadius.sm),
            shadows: danger || !enabled ? const [] : t.accentGlow,
          ),
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 20, color: Colors.white),
                        const SizedBox(width: AppSpace.xs),
                      ],
                      Text(
                        label,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Сегментированный контрол — «таблетка» с плавно едущим индикатором.
class AppSegmentedControl extends StatelessWidget {
  const AppSegmentedControl({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth / items.length;
        return Container(
          height: 40,
          decoration: ShapeDecoration(color: t.fill, shape: squircle(AppRadius.xs + 2)),
          child: Stack(
            children: [
              // Индикатор едет за выбранной вкладкой.
              AnimatedPositioned(
                duration: AppDuration.medium,
                curve: AppCurves.main,
                left: w * index,
                top: 3,
                bottom: 3,
                width: w,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: t.isDark ? t.cardElevated : Colors.white,
                      shape: squircle(AppRadius.xs),
                      shadows: t.shadowSoft,
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: PressScale(
                        scale: 0.98,
                        onTap: () => onChanged(i),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: AppDuration.fast,
                            style: (i == index ? text.titleSmall : text.bodyMedium)!.copyWith(
                              color: i == index ? t.textPrimary : t.textSecondary,
                            ),
                            child: Text(items[i], maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Полоса прогресса с анимированной заливкой градиентом.
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({super.key, required this.value, this.height = 8});

  /// 0..1
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = value.clamp(0.0, 1.0);
    return ClipPath(
      clipper: ShapeBorderClipper(shape: squircle(height)),
      child: SizedBox(
        height: height,
        // Stack по умолчанию сжимается по ребёнку: без expand полоса
        // схлопнется в ноль, а заливка не отрисуется.
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: t.fill),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: v),
              duration: AppDuration.chart,
              curve: AppCurves.main,
              builder: (_, x, _) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: x,
                heightFactor: 1,
                child: DecoratedBox(decoration: BoxDecoration(gradient: t.accent)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Кольцевой прогресс: SweepGradient и круглые концы.
class AppProgressRing extends StatelessWidget {
  const AppProgressRing({
    super.key,
    required this.value,
    this.size = 120,
    this.stroke = 12,
    this.center,
  });

  final double value;
  final double size;
  final double stroke;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
        duration: AppDuration.chart,
        curve: AppCurves.main,
        builder: (_, x, _) => CustomPaint(
          painter: _RingPainter(value: x, stroke: stroke, track: t.fill, colors: [t.accentStart, t.accentEnd]),
          child: Center(child: center),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.value, required this.stroke, required this.track, required this.colors});

  final double value;
  final double stroke;
  final Color track;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.shortestSide - stroke) / 2;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    if (value <= 0) return;
    final sweep = 2 * 3.141592653589793 * value;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [...colors, colors.first],
        startAngle: 0,
        endAngle: 2 * 3.141592653589793,
        transform: const GradientRotation(-3.141592653589793 / 2),
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.141592653589793 / 2,
      sweep,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.track != track;
}

/// Плавный счётчик для крупных чисел.
class CountUp extends StatelessWidget {
  const CountUp({super.key, required this.value, this.style, this.suffix = '', this.fractionDigits = 0});

  final num value;
  final TextStyle? style;
  final String suffix;
  final int fractionDigits;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: AppDuration.counter,
      curve: AppCurves.main,
      builder: (context, v, _) => Text(
        '${v.toStringAsFixed(fractionDigits)}$suffix',
        style: style ?? Theme.of(context).textTheme.displayMedium,
      ),
    );
  }
}

/// Появление элементов списка каскадом: сдвиг по Y + проявление.
class StaggeredItem extends StatelessWidget {
  const StaggeredItem({super.key, required this.index, required this.child, this.step = const Duration(milliseconds: 45)});

  final int index;
  final Widget child;
  final Duration step;

  @override
  Widget build(BuildContext context) {
    // Ограничиваем задержку: на длинных списках ждать секунду нельзя.
    final delay = step * (index.clamp(0, 12));
    return TweenAnimationBuilder<double>(
      key: ValueKey(index),
      tween: Tween(begin: 0, end: 1),
      duration: AppDuration.medium + delay,
      curve: Interval(
        delay.inMilliseconds / (AppDuration.medium.inMilliseconds + delay.inMilliseconds + 1),
        1,
        curve: AppCurves.main,
      ),
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child),
      ),
      child: child,
    );
  }
}
