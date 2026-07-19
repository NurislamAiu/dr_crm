import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Настройки: адреса backend и выход из сессии.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _api;
  late final TextEditingController _rt;

  @override
  void initState() {
    super.initState();
    final c = ref.read(appConfigProvider);
    _api = TextEditingController(text: c.apiBaseUrl);
    _rt = TextEditingController(text: c.realtimeUrl);
  }

  @override
  void dispose() {
    _api.dispose();
    _rt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.read(appConfigProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Менеджер: ${config.userName ?? ''} (${config.role ?? ''})'),
          const SizedBox(height: 16),
          _field(_api, 'API base URL'),
          _field(_rt, 'Realtime URL'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () async {
              await config.setEndpoints(_api.text, _rt.text);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Сохранить'),
          ),
          const Divider(height: 32),
          OutlinedButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('Выйти'),
            onPressed: () async {
              await config.logout();
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );
}
