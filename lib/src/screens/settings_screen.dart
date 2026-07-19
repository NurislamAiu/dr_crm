import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Настройки подключения к backend (DEV). Этап 7 заменит userId на JWT-логин.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.firstRun = false});
  final bool firstRun;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _api;
  late final TextEditingController _rt;
  late final TextEditingController _org;
  late final TextEditingController _user;

  @override
  void initState() {
    super.initState();
    final c = ref.read(appConfigProvider);
    _api = TextEditingController(text: c.apiBaseUrl);
    _rt = TextEditingController(text: c.realtimeUrl);
    _org = TextEditingController(text: c.organizationId);
    _user = TextEditingController(text: c.userId);
  }

  @override
  void dispose() {
    _api.dispose();
    _rt.dispose();
    _org.dispose();
    _user.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(appConfigProvider).save(
          apiBaseUrl: _api.text,
          realtimeUrl: _rt.text,
          organizationId: _org.text,
          userId: _user.text,
        );
    if (mounted && !widget.firstRun) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.firstRun ? 'Подключение к CRM' : 'Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.firstRun)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Укажите адрес backend и id менеджера (DEV-режим).'),
            ),
          _field(_api, 'API base URL', 'http://localhost:3000'),
          _field(_rt, 'Realtime URL', 'http://localhost:3001'),
          _field(_org, 'Organization ID', 'default'),
          _field(_user, 'Manager (user) ID', 'UUID менеджера'),
          const SizedBox(height: 20),
          FilledButton(onPressed: _save, child: const Text('Сохранить')),
          const SizedBox(height: 8),
          const Text(
            'Android-эмулятор: host доступен как 10.0.2.2 вместо localhost.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
        ),
      );
}
