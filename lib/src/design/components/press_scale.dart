import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

/// Нажатие как в iOS: элемент слегка вжимается и мягко возвращается.
///
/// Используется вместо InkWell везде, где есть тап: Material-рябь в этом
/// дизайне выглядит чужеродно и «шумит» поверх стекла и градиентов.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
    this.haptic = true,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 0.96–0.98: глубже — выглядит резиновым, мельче — незаметно.
  final double scale;
  final bool haptic;
  final HitTestBehavior behavior;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AppDuration.pressDown,
    reverseDuration: AppDuration.pressUp,
    lowerBound: 0,
    upperBound: 1,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _down(_) {
    if (!_enabled) return;
    _c.forward();
  }

  void _up([_]) {
    if (!_enabled) return;
    _c.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _down,
      onTapUp: _up,
      onTapCancel: _up,
      onTap: _enabled
          ? () {
              if (widget.haptic) HapticFeedback.lightImpact();
              widget.onTap?.call();
            }
          : null,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              if (widget.haptic) HapticFeedback.mediumImpact();
              widget.onLongPress!.call();
            },
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) => Transform.scale(
          scale: 1 - (1 - widget.scale) * Curves.easeOut.transform(_c.value),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
