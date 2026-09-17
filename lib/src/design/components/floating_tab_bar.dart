import 'package:flutter/material.dart';

import '../tokens.dart';
import 'press_scale.dart';
import 'surfaces.dart';

class AppTabItem {
  const AppTabItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

/// Плавающий таб-бар: стеклянная капсула высотой 62, внутри градиентная
/// «пилюля»-индикатор, которая едет за активной вкладкой.
///
/// Рядом — круглая градиентная кнопка главного действия с еле заметной
/// пульсацией. Контент экрана проезжает под баром: Scaffold(extendBody: true).
class FloatingTabBar extends StatelessWidget {
  const FloatingTabBar({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
    this.onAction,
    this.actionIcon = Icons.add_rounded,
  });

  final List<AppTabItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  /// Главное действие: если null — кнопка не показывается.
  final VoidCallback? onAction;
  final IconData actionIcon;

  static const double height = 62;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, bottom > 0 ? bottom - 4 : AppSpace.sm),
      child: Row(
        children: [
          Expanded(
            child: GlassSurface(
              radius: height / 2,
              child: SizedBox(
                height: height,
                child: LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth / items.length;
                    return Stack(
                      children: [
                        // Индикатор-пилюля едет за вкладкой.
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeOutCubic,
                          left: w * index,
                          top: 6,
                          bottom: 6,
                          width: w,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: DecoratedBox(
                              decoration: ShapeDecoration(
                                gradient: t.accent,
                                shape: squircle((height - 12) / 2),
                                shadows: t.accentGlow,
                              ),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            for (var i = 0; i < items.length; i++)
                              Expanded(
                                child: PressScale(
                                  scale: 0.94,
                                  onTap: () => onChanged(i),
                                  child: _TabContent(item: items[i], active: i == index),
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          if (onAction != null) ...[
            const SizedBox(width: AppSpace.sm),
            _ActionButton(icon: actionIcon, onTap: onAction!),
          ],
        ],
      ),
    );
  }
}

class _TabContent extends StatelessWidget {
  const _TabContent({required this.item, required this.active});

  final AppTabItem item;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = active ? Colors.white : t.textSecondary;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedScale(
          duration: AppDuration.fast,
          curve: AppCurves.main,
          scale: active ? 1.06 : 1,
          child: Icon(item.icon, size: 21, color: color),
        ),
        const SizedBox(height: 2),
        AnimatedDefaultTextStyle(
          duration: AppDuration.fast,
          style: (active
                  ? Theme.of(context).textTheme.labelSmall
                  : Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w500))!
              .copyWith(color: color),
          child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

/// Круглая кнопка главного действия 62×62 с медленной пульсацией.
class _ActionButton extends StatefulWidget {
  const _ActionButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return PressScale(
      scale: 0.94,
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) => Transform.scale(
          scale: 1 + 0.04 * Curves.easeInOut.transform(_c.value),
          child: child,
        ),
        child: Container(
          width: FloatingTabBar.height,
          height: FloatingTabBar.height,
          decoration: ShapeDecoration(
            gradient: t.accent,
            shape: const CircleBorder(),
            shadows: t.accentGlow,
          ),
          child: Icon(widget.icon, color: Colors.white, size: 26),
        ),
      ),
    );
  }
}
