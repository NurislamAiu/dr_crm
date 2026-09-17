import 'package:flutter/material.dart';

import '../tokens.dart';
import 'press_scale.dart';
import 'surfaces.dart';

/// Сгруппированный список в духе iOS Settings: карточка-сквиркл, внутри
/// строки с цветной иконкой, разделители с отступом под иконку.
class AppSectionCard extends StatelessWidget {
  const AppSectionCard({super.key, required this.children, this.title, this.footer});

  final List<Widget> children;
  final String? title;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.xs),
            child: Text(title!.toUpperCase(), style: text.labelSmall?.copyWith(color: t.textSecondary)),
          ),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1)
                  // Разделитель начинается под текстом, а не под иконкой.
                  Padding(
                    padding: const EdgeInsets.only(left: 58),
                    child: Divider(height: 0.5, thickness: 0.5, color: t.separator),
                  ),
              ],
            ],
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.xs, AppSpace.md, 0),
            child: Text(footer!, style: text.bodySmall),
          ),
      ],
    );
  }
}

/// Строка списка: иконка 30×30 в цветном сквиркле, заголовок, подзаголовок,
/// шеврон либо произвольный trailing.
class AppTile extends StatelessWidget {
  const AppTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.trailing,
    this.onTap,
    this.showChevron = true,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final tint = destructive ? t.danger : (iconColor ?? t.accentSolid);

    return PressScale(
      scale: 0.985,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: 11),
        child: Row(
          children: [
            if (icon != null) ...[
              Container(
                width: 30,
                height: 30,
                decoration: ShapeDecoration(color: tint, shape: squircle(AppRadius.xs - 2)),
                child: Icon(icon, size: 17, color: Colors.white),
              ),
              const SizedBox(width: AppSpace.sm),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyLarge?.copyWith(color: destructive ? t.danger : t.textPrimary),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: AppSpace.xs), trailing!],
            if (trailing == null && showChevron && onTap != null)
              Icon(Icons.chevron_right_rounded, size: 20, color: t.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// Модальный лист: grab handle, «Отмена» слева, «Готово» справа жирным,
/// скругление только сверху, отступ под клавиатуру.
class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.child,
    this.title,
    this.onCancel,
    this.onDone,
    this.doneLabel = 'Готово',
    this.cancelLabel = 'Отмена',
    this.doneEnabled = true,
  });

  final Widget child;
  final String? title;
  final VoidCallback? onCancel;
  final VoidCallback? onDone;
  final String doneLabel;
  final String cancelLabel;
  final bool doneEnabled;

  /// Показать лист. scrollControlled — чтобы лист рос под клавиатуру.
  static Future<T?> show<T>(BuildContext context, {required WidgetBuilder builder}) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: builder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    return Padding(
      // Лист поднимается над клавиатурой.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: t.card, shape: squircleTop(AppRadius.xl)),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: AppSpace.xs),
              Container(
                width: 36,
                height: 5,
                decoration: ShapeDecoration(color: t.separator, shape: squircle(3)),
              ),
              if (title != null || onCancel != null || onDone != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.sm, AppSpace.md, AppSpace.xs),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 80,
                        child: onCancel == null
                            ? null
                            : PressScale(
                                onTap: onCancel,
                                child: Text(cancelLabel, style: text.bodyLarge?.copyWith(color: t.accentSolid)),
                              ),
                      ),
                      Expanded(
                        child: Text(
                          title ?? '',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium,
                        ),
                      ),
                      SizedBox(
                        width: 80,
                        child: onDone == null
                            ? null
                            : Align(
                                alignment: Alignment.centerRight,
                                child: PressScale(
                                  onTap: doneEnabled ? onDone : null,
                                  child: Text(
                                    doneLabel,
                                    style: text.bodyLarge?.copyWith(
                                      color: doneEnabled ? t.accentSolid : t.textTertiary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              Flexible(child: child),
              const SizedBox(height: AppSpace.xs),
            ],
          ),
        ),
      ),
    );
  }
}

/// Пустое состояние: иконка в градиентном сквиркле, вокруг — пульсирующие
/// кольца. Без стоковых картинок.
class EmptyState extends StatefulWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<EmptyState> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 160,
              height: 160,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _c,
                    builder: (_, _) => CustomPaint(
                      size: const Size.square(160),
                      painter: _PulseRingsPainter(progress: _c.value, color: t.accentSolid),
                    ),
                  ),
                  Container(
                    width: 76,
                    height: 76,
                    decoration: ShapeDecoration(
                      gradient: t.accent,
                      shape: squircle(AppRadius.md),
                      shadows: t.accentGlow,
                    ),
                    child: Icon(widget.icon, size: 34, color: Colors.white),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Text(widget.title, textAlign: TextAlign.center, style: text.headlineSmall),
            if (widget.message != null) ...[
              const SizedBox(height: AppSpace.xs),
              Text(widget.message!, textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: t.textSecondary)),
            ],
            if (widget.actionLabel != null && widget.onAction != null) ...[
              const SizedBox(height: AppSpace.lg),
              PressScale(
                onTap: widget.onAction,
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                  decoration: ShapeDecoration(gradient: t.accent, shape: squircle(23), shadows: t.accentGlow),
                  child: Center(
                    child: Text(widget.actionLabel!, style: text.titleSmall?.copyWith(color: Colors.white)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PulseRingsPainter extends CustomPainter {
  const _PulseRingsPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      // Кольца стартуют со сдвигом, чтобы шли волной.
      final p = (progress + i / 3) % 1;
      final radius = 42 + p * 38;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: (1 - p) * 0.35);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_PulseRingsPainter old) => old.progress != progress || old.color != color;
}
