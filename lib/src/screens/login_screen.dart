import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/app_theme.dart';

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
  bool _showAdvanced = false;
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
    final sem = context.semantic;
    return Scaffold(
      body: Column(
        children: [
          // Градиентный герой
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 36),
            decoration: const BoxDecoration(
              gradient: brandGradient,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(36)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.chat_bubble_rounded, color: Colors.white, size: 34),
                    ),
                    const SizedBox(height: 20),
                    const Text('CRM WhatsApp',
                        style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                    const SizedBox(height: 6),
                    Text('Общение с клиентами в одном месте',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 14)),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              children: [
                Text('Вход', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                _label('Email'),
                TextField(controller: _email, decoration: const InputDecoration(prefixIcon: Icon(Icons.mail_outline))),
                const SizedBox(height: 14),
                _label('Пароль'),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.lock_outline)),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
                    child: Text(_showAdvanced ? 'Скрыть настройки сервера' : 'Настройки сервера'),
                  ),
                ),
                if (_showAdvanced) ...[
                  _label('API base URL'),
                  TextField(controller: _api, decoration: const InputDecoration(prefixIcon: Icon(Icons.dns_outlined))),
                  const SizedBox(height: 14),
                  _label('Realtime URL'),
                  TextField(controller: _rt, decoration: const InputDecoration(prefixIcon: Icon(Icons.bolt_outlined))),
                  const SizedBox(height: 8),
                ],
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error!, style: const TextStyle(color: Colors.red))),
                    ]),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _login,
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Войти'),
                ),
                const SizedBox(height: 14),
                Center(
                  child: Text('DEV: manager@example.com / password',
                      style: TextStyle(fontSize: 12, color: sem.textSecondary)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4),
        child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.semantic.textSecondary)),
      );
}
