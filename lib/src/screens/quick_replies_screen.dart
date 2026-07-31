import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../data/quick_replies_service.dart';
import '../state/providers.dart';
import 'soft_ui.dart';

const _pageBg = Color(0xFFF1F8F6);

/// Управление быстрыми ответами (шаблонами сообщений).
/// Шаблоны общие для всех менеджеров, вставляются в чате кнопкой ⚡.
class QuickRepliesScreen extends ConsumerWidget {
  const QuickRepliesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final replies = ref.watch(quickRepliesProvider);
    return Scaffold(
      backgroundColor: _pageBg,
      body: Column(
        children: [
          SoftHeader(
            color: kTeal,
            colorDeep: kTealDeep,
            title: 'Быстрые ответы',
            dateLabel: 'Шаблоны сообщений',
            showBack: true,
            actions: [
              SoftHeaderButton(
                icon: Iconsax.add,
                filled: true,
                tooltip: 'Новый шаблон',
                onTap: () => _edit(context, ref),
              ),
            ],
          ),
          Expanded(
            child: Container(
              transform: Matrix4.translationValues(0, -22, 0),
              decoration: const BoxDecoration(
                color: _pageBg,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: replies.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text('Ошибка: $e', textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: kSub)),
                  ),
                ),
                data: (items) {
                  if (items.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(22)),
                            child: const Icon(Iconsax.flash_1, size: 34, color: kTeal),
                          ),
                          const SizedBox(height: 16),
                          const Text('Пока нет шаблонов', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: kInk)),
                          const SizedBox(height: 6),
                          const Text('Создайте шаблон кнопкой + — он появится\nв чате по кнопке ⚡',
                              textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: kSub)),
                        ]),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(15, 22, 15, 28),
                    itemCount: items.length,
                    itemBuilder: (context, i) => _card(context, ref, items[i]),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, WidgetRef ref, QuickReply r) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => _edit(context, ref, existing: r),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 10, 13),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(13)),
                child: const Icon(Iconsax.flash_1, size: 19, color: kTealDeep),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: kInk)),
                  const SizedBox(height: 3),
                  Text(r.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: kSub, height: 1.3)),
                ]),
              ),
              IconButton(
                icon: const Icon(Iconsax.trash, size: 19, color: Color(0xFFD9776F)),
                tooltip: 'Удалить',
                onPressed: () => _confirmDelete(context, ref, r),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, QuickReply r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Удалить шаблон?'),
        content: Text('«${r.title}» будет удалён у всех менеджеров.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC6403C)),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(quickRepliesServiceProvider).delete(r.id);
  }

  /// Создание/редактирование шаблона (нижний шит).
  Future<void> _edit(BuildContext context, WidgetRef ref, {QuickReply? existing}) async {
    final res = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _EditSheet(existing: existing),
    );
    if (res == null) return;
    final t = res.$1.trim();
    final tx = res.$2.trim();
    if (tx.isEmpty) return;
    final svc = ref.read(quickRepliesServiceProvider);
    if (existing == null) {
      await svc.add(title: t.isEmpty ? tx.split('\n').first : t, text: tx);
    } else {
      await svc.update(existing.id, title: t.isEmpty ? tx.split('\n').first : t, text: tx);
    }
  }
}

/// Шит редактирования шаблона — свои контроллеры (живут вместе с шитом,
/// поэтому анимация закрытия не трогает уже уничтоженные).
class _EditSheet extends StatefulWidget {
  const _EditSheet({this.existing});
  final QuickReply? existing;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _title;
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    _text = TextEditingController(text: widget.existing?.text ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const SizedBox(height: 16),
            Text(widget.existing == null ? 'Новый шаблон' : 'Изменить шаблон',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kInk)),
            const SizedBox(height: 14),
            TextField(
              controller: _title,
              autofocus: widget.existing == null,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Название (например: Приветствие)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _text,
              minLines: 4,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Текст сообщения, который отправится клиенту'),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: kTeal,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => Navigator.pop(context, (_title.text, _text.text)),
                child: Text(widget.existing == null ? 'Создать' : 'Сохранить',
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
