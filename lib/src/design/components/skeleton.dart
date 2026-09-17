import 'package:flutter/material.dart';

import '../tokens.dart';

/// Серая «заготовка» контента на время загрузки.
///
/// Спиннер по центру пустого экрана заставляет ждать в никуда: непонятно, что
/// грузится и сколько там будет. Заготовки показывают форму будущего списка,
/// поэтому переход к данным получается без скачка.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 12, this.radius = 6});

  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base = t.isDark ? Colors.white : Colors.black;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: ShapeDecoration(
          // Пульсация вместо бегущего блика: дешевле для слабых телефонов.
          color: base.withValues(alpha: 0.05 + 0.04 * _c.value),
          shape: squircle(widget.radius),
        ),
      ),
    );
  }
}

/// Список карточек-заготовок: аватар, две строки текста.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 7, this.avatar = true, this.padding});

  final int count;
  final bool avatar;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListView.builder(
      padding: padding ?? const EdgeInsets.fromLTRB(15, 18, 15, 24),
      itemCount: count,
      // Заготовки не интерактивны — скролл им не нужен.
      physics: const NeverScrollableScrollPhysics(),
      itemBuilder: (_, i) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(13),
        decoration: ShapeDecoration(color: t.card, shape: squircle(AppRadius.md)),
        child: Row(children: [
          if (avatar) ...[
            const Skeleton(width: 44, height: 44, radius: 15),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Разная длина строк — иначе выглядит как таблица, а не список.
              Skeleton(width: 90.0 + (i % 3) * 40, height: 13),
              const SizedBox(height: 8),
              Skeleton(width: 140.0 + (i % 4) * 30, height: 11),
            ]),
          ),
          const SizedBox(width: 12),
          const Skeleton(width: 34, height: 11),
        ]),
      ),
    );
  }
}
