import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../state/providers.dart';
import 'soft_ui.dart';

/// Экран входа менеджера — только Firebase Auth (email + пароль).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
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
      await config.setBackend('firebase');
      // Вход через Firebase Auth + профиль/роль из users/{uid}.
      final auth = ref.read(firebaseAuthServiceProvider);
      await auth.signIn(_email.text.trim(), _password.text);
      final profile = await auth.loadProfile();
      if (profile == null) {
        await auth.signOut();
        throw Exception('Профиль менеджера не найден (нет users/{uid})');
      }
      if (!profile.isActive) {
        await auth.signOut();
        throw Exception('Аккаунт отключён');
      }
      await config.setSession(token: 'firebase', userId: profile.uid, userName: profile.name, role: profile.role);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F8F6),
      body: Column(
        children: [
          // Тил-герой со скруглением.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [kTeal, kTealDeep],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(36)),
              boxShadow: [BoxShadow(color: kTealDeep.withValues(alpha: 0.22), blurRadius: 22, offset: const Offset(0, 10))],
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 42),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 68,
                      height: 68,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 14, offset: const Offset(0, 5))],
                      ),
                      child: Image.asset('assets/logo.png', fit: BoxFit.contain),
                    ),
                    const SizedBox(height: 20),
                    const Text('DR.TOITAYEV',
                        style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                    const SizedBox(height: 6),
                    Text('WhatsApp-CRM клиники',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 14)),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
              children: [
                const Text('Вход', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: kInk, letterSpacing: -0.3)),
                const SizedBox(height: 16),
                _label('Email'),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  enabled: !_busy,
                  style: const TextStyle(fontSize: 15, color: kInk),
                  decoration: _fieldDeco(hint: 'manager@clinic.kz', prefix: const Icon(Iconsax.sms, size: 20, color: kSub)),
                ),
                const SizedBox(height: 14),
                _label('Пароль'),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  enabled: !_busy,
                  onSubmitted: (_) => _busy ? null : _login(),
                  style: const TextStyle(fontSize: 15, color: kInk),
                  decoration: _fieldDeco(
                    hint: '••••••••',
                    prefix: const Icon(Iconsax.lock_1, size: 20, color: kSub),
                    suffix: IconButton(
                      icon: Icon(_obscure ? Iconsax.eye_slash : Iconsax.eye, size: 20, color: kSub),
                      tooltip: _obscure ? 'Показать пароль' : 'Скрыть пароль',
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(top: 14),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFBEDEC),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(children: [
                      const Icon(Iconsax.info_circle, color: Color(0xFFC6403C), size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error!, style: const TextStyle(color: Color(0xFFC6403C), fontSize: 13))),
                    ]),
                  ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 54,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kTeal,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    onPressed: _busy ? null : _login,
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                        : const Text('Войти', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Белое поле с мягкой рамкой — не сливается с фоном страницы.
  InputDecoration _fieldDeco({String? hint, Widget? prefix, Widget? suffix}) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 14.5, color: kSub.withValues(alpha: 0.55)),
        filled: true,
        fillColor: Colors.white,
        prefixIcon: prefix,
        suffixIcon: suffix,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: kTeal, width: 1.6),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.06)),
        ),
      );

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4),
        child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kSub)),
      );
}
