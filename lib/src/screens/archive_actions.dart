import 'package:flutter/material.dart';

/// Обёртка карточки лида/VIP с архивом.
/// Активные: свайп влево → в архив (с «Отменить»); тап → действие (правка).
/// В архиве: кнопки «Вернуть» и «Удалить навсегда».
class ArchiveActions extends StatelessWidget {
  const ArchiveActions({
    super.key,
    required this.itemKey,
    required this.archived,
    required this.label,
    required this.onTap,
    this.onLongPress,
    required this.onArchive,
    required this.onRestore,
    required this.onDeleteForever,
    required this.child,
  });

  final Key itemKey;
  final bool archived;
  final String label;
  final VoidCallback? onTap;

  /// Долгое нажатие (копирование номера).
  final VoidCallback? onLongPress;
  final Future<void> Function() onArchive;
  final Future<void> Function() onRestore;
  final Future<void> Function() onDeleteForever;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!archived) {
      return Dismissible(
        key: itemKey,
        direction: DismissDirection.endToStart,
        background: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 22),
          decoration: BoxDecoration(color: const Color(0xFFEF9F27), borderRadius: BorderRadius.circular(18)),
          child: const Row(mainAxisAlignment: MainAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.archive_outlined, color: Colors.white, size: 22),
            SizedBox(width: 6),
            Text('В архив', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ]),
        ),
        onDismissed: (_) async {
          await onArchive();
          if (!context.mounted) return;
          // Прячем предыдущий снекбар, иначе при серии архивирований они
          // копятся в очередь и висят на экране.
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
              content: const Text('В архиве'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
              action: SnackBarAction(label: 'Отменить', onPressed: () => onRestore()),
            ));
        },
        child: GestureDetector(onTap: onTap, onLongPress: onLongPress, behavior: HitTestBehavior.opaque, child: child),
      );
    }

    // Режим архива — карточка + кнопки вернуть/удалить.
    return Padding(
      key: itemKey,
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(children: [
        child,
        Padding(
          padding: const EdgeInsets.only(top: 2, right: 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton.icon(
              icon: const Icon(Icons.unarchive_outlined, size: 18),
              label: const Text('Вернуть'),
              onPressed: () => onRestore(),
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_forever_outlined, size: 18, color: Colors.red),
              label: const Text('Удалить', style: TextStyle(color: Colors.red)),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    title: const Text('Удалить навсегда?'),
                    content: Text('$label будет удалён без возможности восстановления.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
                      FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(d, true), child: const Text('Удалить')),
                    ],
                  ),
                );
                if (ok == true) await onDeleteForever();
              },
            ),
          ]),
        ),
      ]),
    );
  }
}
