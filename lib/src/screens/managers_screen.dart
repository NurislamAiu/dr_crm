import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/app_theme.dart';

const _roleLabels = {'admin': 'Админ', 'manager': 'Менеджер', 'viewer': 'Наблюдатель'};

/// Экран управления менеджерами (только для админа).
class ManagersScreen extends ConsumerStatefulWidget {
  const ManagersScreen({super.key});

  @override
  ConsumerState<ManagersScreen> createState() => _ManagersScreenState();
}

class _ManagersScreenState extends ConsumerState<ManagersScreen> {
  List<Map<String, dynamic>>? _users;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final users = await ref.read(apiClientProvider).listManagers();
      if (mounted) setState(() => _users = users);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> u, bool active) async {
    try {
      await ref.read(apiClientProvider).updateManager(u['id'] as String, {'isActive': active});
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final me = ref.read(appConfigProvider).userId;
    return Scaffold(
      appBar: AppBar(title: const Text('Менеджеры', style: TextStyle(fontWeight: FontWeight.w800))),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.brand,
        icon: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white),
        label: const Text('Добавить', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        onPressed: () => _openEditor(),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: _error != null
            ? _center(Icons.cloud_off, 'Ошибка', _error!, dark)
            : _users == null
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                      children: [
                        for (final u in _users!) _card(u, u['id'] == me, dark),
                        if (_users!.isEmpty) _center(Icons.group_outlined, 'Нет менеджеров', 'Добавьте первого', dark),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _card(Map<String, dynamic> u, bool isMe, bool dark) {
    final active = u['isActive'] == true;
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
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w800, fontSize: 18)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(name.isEmpty ? '—' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700))),
                if (isMe) ...[
                  const SizedBox(width: 6),
                  const Text('вы', style: TextStyle(color: AppColors.brand, fontWeight: FontWeight.w700, fontSize: 12)),
                ],
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
          IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _openEditor(existing: u)),
          Switch(value: active, activeThumbColor: AppColors.brand, onChanged: isMe ? null : (v) => _toggleActive(u, v)),
        ]),
      ),
    );
  }

  Widget _center(IconData icon, String title, String sub, bool dark) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 52, color: AppColors.brand.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(sub, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: context.semantic.textSecondary)),
          ]),
        ),
      );

  Future<void> _openEditor({Map<String, dynamic>? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ManagerEditor(existing: existing),
    );
    if (saved == true) await _load();
  }
}

/// Форма создания/редактирования менеджера.
class _ManagerEditor extends ConsumerStatefulWidget {
  const _ManagerEditor({this.existing});
  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_ManagerEditor> createState() => _ManagerEditorState();
}

class _ManagerEditorState extends ConsumerState<_ManagerEditor> {
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
      _role = (ex['role'] ?? 'manager') as String;
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
    final api = ref.read(apiClientProvider);
    try {
      if (_editing) {
        final patch = <String, dynamic>{'name': _name.text.trim(), 'role': _role};
        if (_password.text.trim().isNotEmpty) patch['password'] = _password.text.trim();
        await api.updateManager(widget.existing!['id'] as String, patch);
      } else {
        await api.createManager(email: _email.text.trim(), name: _name.text.trim(), password: _password.text.trim(), role: _role);
      }
      if (mounted) Navigator.of(context).pop(true);
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
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF12191E) : const Color(0xFFF2F5F7),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
        child: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Container(width: 42, height: 5, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(3))),
            ),
            Text(_editing ? 'Редактирование менеджера' : 'Новый менеджер', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            _field(_email, 'Email', Icons.mail_outline, enabled: !_editing, keyboard: TextInputType.emailAddress,
                validator: (v) => (!_editing && (v == null || !v.contains('@'))) ? 'Неверный email' : null),
            _field(_name, 'Имя', Icons.badge_outlined, validator: (v) => (v == null || v.trim().isEmpty) ? 'Укажите имя' : null),
            _field(_password, _editing ? 'Новый пароль (если менять)' : 'Пароль (от 6 символов)', Icons.lock_outline,
                obscure: true,
                validator: (v) => (!_editing && (v == null || v.trim().length < 6)) ? 'Минимум 6 символов' : null),
            const SizedBox(height: 4),
            Text('Роль', style: TextStyle(fontSize: 12.5, color: context.semantic.textSecondary)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final e in _roleLabels.entries)
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
              height: 50,
              width: double.infinity,
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
