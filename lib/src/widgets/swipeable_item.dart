import 'package:flutter/material.dart';

/// Элемент списка: тап — действие (правка), свайп влево — удаление с подтверждением.
class SwipeableItem extends StatelessWidget {
  const SwipeableItem({
    super.key,
    required this.itemKey,
    required this.onTap,
    required this.onDelete,
    required this.title,
    required this.child,
  });

  final Key itemKey;
  final VoidCallback onTap;
  final Future<void> Function() onDelete;

  /// Что показать в диалоге подтверждения («Удалить лид №1?»).
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: itemKey,
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(color: Colors.red.shade500, borderRadius: BorderRadius.circular(18)),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 26),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (dialog) => AlertDialog(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                title: const Text('Удалить?'),
                content: Text(title),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Отмена')),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('Удалить'),
                  ),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) async {
        try {
          await onDelete();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Удалено'), behavior: SnackBarBehavior.floating),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Не удалось удалить: $e'), backgroundColor: Colors.red.shade700),
            );
          }
        }
      },
      child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: child),
    );
  }
}
