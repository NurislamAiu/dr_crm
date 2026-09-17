import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../data/prank_service.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/prank_host.dart';

const _roleLabels = {'admin': 'Админ', 'administrator': 'Админ', 'manager': 'Менеджер', 'viewer': 'Наблюдатель'};

/// Менеджеры в firebase-режиме (Firestore users + Cloud Functions).
class FirebaseManagersScreen extends ConsumerWidget {
  const FirebaseManagersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final me = ref.read(appConfigProvider).userId;
    // Кэшированный provider — не пересоздаём подписку на users при rebuild.
    final managersAsync = ref.watch(managersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Менеджеры', style: TextStyle(fontWeight: FontWeight.w800))),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.brand,
        icon: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white),
        label: const Text('Добавить', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        onPressed: () => _openEditor(context),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: Builder(
          builder: (context) {
            if (managersAsync.hasError) {
              return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Ошибка: ${managersAsync.error}')));
            }
            if (!managersAsync.hasValue) return const Center(child: CircularProgressIndicator());
            final users = managersAsync.value!;
            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
              children: [for (final u in users) _card(context, ref, u, u['id'] == me, dark)],
            );
          },
        ),
      ),
    );
  }

  Widget _card(BuildContext context, WidgetRef ref, Map<String, dynamic> u, bool isMe, bool dark) {
    final active = u['isActive'] != false;
    final role = (u['role'] ?? 'manager') as String;
    final name = (u['name'] ?? '') as String;
    return Opacity(
      opacity: active ? 1 : 0.55,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF1B242B) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 10, offset: const Offset(0, 3))],
        ),
        child: Row(children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.brand.withValues(alpha: 0.15),
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w800, fontSize: 18)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(name.isEmpty ? '—' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700))),
                if (isMe) ...[const SizedBox(width: 6), const Text('вы', style: TextStyle(color: AppColors.brand, fontWeight: FontWeight.w700, fontSize: 12))],
              ]),
              const SizedBox(height: 2),
              Text((u['email'] ?? '') as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: context.semantic.textSecondary)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: AppColors.brand.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(7)),
                child: Text(_roleLabels[role] ?? role, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.brand)),
              ),
            ]),
          ),
          // Розыгрыш: картинка на весь экран у менеджера на пару секунд.
          if (!isMe)
            IconButton(
              icon: const Icon(Icons.emoji_emotions_outlined, size: 20),
              tooltip: 'Прикол',
              onPressed: () => _prank(context, ref, u),
            ),
          IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _openEditor(context, existing: u)),
          Switch(
            value: active,
            activeThumbColor: AppColors.brand,
            onChanged: isMe ? null : (v) async {
              try {
                await ref.read(firebaseManagerServiceProvider).update(u['id'] as String, {'isActive': v});
              } catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
              }
            },
          ),
        ]),
      ),
    );
  }

  /// Показать менеджеру картинку на 2 секунды. Картинка выбирается один раз
  /// и запоминается — дальше розыгрыш это одно нажатие.
  Future<void> _prank(BuildContext context, WidgetRef ref, Map<String, dynamic> u) async {
    final svc = ref.read(prankServiceProvider);
    final me = ref.read(appConfigProvider);
    final uid = u['id'] as String;
    final name = ((u['name'] ?? '') as String).trim();
    final messenger = ScaffoldMessenger.of(context);

    Future<void> fire(String url) async {
      await svc.send(uid: uid, url: url, seconds: 2, fromName: me.userName);
      messenger.showSnackBar(SnackBar(content: Text('Отправлено${name.isEmpty ? '' : ' — $name'} 😄')));
    }

    Future<String?> pick() async {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (x == null) return null;
      return svc.setImage(bytes: await x.readAsBytes(), contentType: x.mimeType ?? 'image/jpeg');
    }

    try {
      final hasAsset = await prankAssetExists();
      final current = await svc.image();
      if (!hasAsset && (current == null || current.isEmpty)) {
        final url = await pick();
        if (url == null) return;
        await fire(url);
        return;
      }
      if (!context.mounted) return;
      final action = await showModalBottomSheet<String>(
        context: context,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (sheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(children: [
                const Icon(Icons.emoji_emotions_outlined, size: 26, color: AppColors.brand),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(name.isEmpty ? 'Менеджеру' : name,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
            // Встроенная картинка уходит мгновенно: она уже в сборке у всех.
            if (hasAsset)
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(kPrankAsset, width: 34, height: 34, fit: BoxFit.cover),
                ),
                title: const Text('Системная картинка (мгновенно)'),
                subtitle: const Text('2 секунды на весь экран'),
                onTap: () => Navigator.pop(sheet, 'asset'),
              ),
            if (current != null && current.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.send_rounded, color: AppColors.brand),
                title: const Text('Показать свою картинку (2 сек)'),
                onTap: () => Navigator.pop(sheet, 'send'),
              ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Выбрать другую картинку'),
              onTap: () => Navigator.pop(sheet, 'pick'),
            ),
          ]),
        ),
      );
      if (action == 'asset') {
        await fire(PrankItem.asset);
      } else if (action == 'send' && current != null) {
        await fire(current);
      } else if (action == 'pick') {
        final url = await pick();
        if (url != null) await fire(url);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не получилось: $e')));
    }
  }

  Future<void> _openEditor(BuildContext context, {Map<String, dynamic>? existing}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FbManagerEditor(existing: existing),
    );
  }
}

class _FbManagerEditor extends ConsumerStatefulWidget {
  const _FbManagerEditor({this.existing});
  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_FbManagerEditor> createState() => _FbManagerEditorState();
}

class _FbManagerEditorState extends ConsumerState<_FbManagerEditor> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  String _role = 'manager';
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _email.text = (ex['email'] ?? '') as String;
      _name.text = (ex['name'] ?? '') as String;
      final r = (ex['role'] ?? 'manager') as String;
      _role = r == 'administrator' ? 'admin' : r;
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final svc = ref.read(firebaseManagerServiceProvider);
    try {
      if (_editing) {
        final patch = <String, dynamic>{'name': _name.text.trim(), 'role': _role};
        if (_password.text.trim().isNotEmpty) patch['password'] = _password.text.trim();
        await svc.update(widget.existing!['id'] as String, patch);
      } else {
        await svc.create(email: _email.text.trim(), name: _name.text.trim(), password: _password.text.trim(), role: _role);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(color: dark ? const Color(0xFF12191E) : const Color(0xFFF2F5F7), borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
        child: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 42, height: 5, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(3)))),
            Text(_editing ? 'Редактирование менеджера' : 'Новый менеджер', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            _field(_email, 'Email', Icons.mail_outline, enabled: !_editing, keyboard: TextInputType.emailAddress, validator: (v) => (!_editing && (v == null || !v.contains('@'))) ? 'Неверный email' : null),
            _field(_name, 'Имя', Icons.badge_outlined, validator: (v) => (v == null || v.trim().isEmpty) ? 'Укажите имя' : null),
            _field(_password, _editing ? 'Новый пароль (если менять)' : 'Пароль (от 6)', Icons.lock_outline, obscure: true, validator: (v) => (!_editing && (v == null || v.trim().length < 6)) ? 'Минимум 6 символов' : null),
            const SizedBox(height: 4),
            Text('Роль', style: TextStyle(fontSize: 12.5, color: context.semantic.textSecondary)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final e in const {'admin': 'Админ', 'manager': 'Менеджер', 'viewer': 'Наблюдатель'}.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: _role == e.key,
                  selectedColor: AppColors.brand.withValues(alpha: 0.18),
                  labelStyle: TextStyle(fontWeight: _role == e.key ? FontWeight.w700 : FontWeight.w500, color: _role == e.key ? AppColors.brand : null),
                  onSelected: (_) => setState(() => _role = e.key),
                ),
            ]),
            const SizedBox(height: 18),
            SizedBox(
              height: 50, width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                    : Text(_editing ? 'Сохранить' : 'Создать менеджера', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon, {bool enabled = true, bool obscure = false, TextInputType? keyboard, String? Function(String?)? validator}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: c,
        enabled: enabled,
        obscureText: obscure,
        keyboardType: keyboard,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 19),
          filled: true,
          fillColor: dark ? const Color(0xFF232E36) : Colors.white,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: AppColors.brand, width: 1.5)),
        ),
      ),
    );
  }
}
