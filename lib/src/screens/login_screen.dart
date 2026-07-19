import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Экран входа менеджера (JWT). Заменил DEV-заголовок x-user-id.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late final TextEditingController _api;
  late final TextEditingController _rt;
  final _email = TextEditingController(text: 'manager@example.com');
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

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
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final config = ref.read(appConfigProvider);
    try {
      await config.setEndpoints(_api.text, _rt.text);
      final data = await ref.read(apiClientProvider).login(_email.text.trim(), _password.text);
      final user = data['user'] as Map<String, dynamic>;
      await config.setSession(
        token: data['token'] as String,
        userId: user['id'] as String,
        userName: user['name'] as String? ?? '',
        role: user['role'] as String? ?? 'manager',
      );
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Вход в CRM')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field(_api, 'API base URL'),
          _field(_rt, 'Realtime URL'),
          const Divider(height: 24),
          _field(_email, 'Email'),
          _field(_password, 'Пароль', obscure: true),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _login,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Войти'),
          ),
          const SizedBox(height: 8),
          const Text('DEV: manager@example.com / password', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {bool obscure = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          obscureText: obscure,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );
}
