import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../state/providers.dart';
import 'soft_ui.dart';

/// Зона ожидания: в систему вошёл другой менеджер.
///
/// Раньше здесь сразу выкидывало на экран входа. Теперь 30 секунд ждём —
/// если тот менеджер вышел (или просто перезашёл с другого телефона),
/// работа продолжается без повторного логина. Возвращает true, если
/// система освободилась, false — если время вышло или нажали «Выйти».
class SessionWaitScreen extends ConsumerStatefulWidget {
  const SessionWaitScreen({super.key, required this.byName, this.seconds = 30});
  final String byName;
  final int seconds;

  @override
  ConsumerState<SessionWaitScreen> createState() => _SessionWaitScreenState();
}

class _SessionWaitScreenState extends ConsumerState<SessionWaitScreen> {
  late int _left = widget.seconds;
  Timer? _timer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left--);
      if (_left <= 0) _finish(false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _finish(bool freed) {
    if (_done || !mounted) return;
    _done = true;
    _timer?.cancel();
    Navigator.of(context).pop(freed);
  }

  @override
  Widget build(BuildContext context) {
    // Как только система освободилась — сразу возвращаемся к работе.
    ref.listen(activeSessionProvider, (_, next) {
      if (next.value == null && next.hasValue) _finish(true);
    });
    final progress = (_left / widget.seconds).clamp(0.0, 1.0);

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F8F6),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 28, 28, 28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 118,
                  height: 118,
                  child: Stack(alignment: Alignment.center, children: [
                    SizedBox(
                      width: 118,
                      height: 118,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: progress, end: progress),
                        duration: const Duration(milliseconds: 900),
                        builder: (_, v, _) => CircularProgressIndicator(
                          value: v,
                          strokeWidth: 6,
                          backgroundColor: kTeal.withValues(alpha: 0.15),
                          valueColor: const AlwaysStoppedAnimation(kTealDeep),
                        ),
                      ),
                    ),
                    Text('$_left',
                        style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            color: kInk,
                            fontFeatures: [FontFeature.tabularFigures()])),
                  ]),
                ),
                const SizedBox(height: 22),
                const Text('Ожидание очереди',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: kInk, letterSpacing: -0.3)),
                const SizedBox(height: 8),
                Text(
                  widget.byName.isEmpty
                      ? 'Сейчас в системе другой менеджер. Ждём — как только он выйдет, Вы продолжите работу.'
                      : 'Сейчас в системе ${widget.byName}. Ждём — как только освободится, Вы продолжите работу без повторного входа.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: kSub, height: 1.4),
                ),
                const SizedBox(height: 26),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFC6403C),
                      side: const BorderSide(color: Color(0xFFE7D3D2)),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Iconsax.logout, size: 18),
                    label: const Text('Выйти сейчас',
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                    onPressed: () => _finish(false),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
