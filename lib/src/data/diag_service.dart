import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Удалённая диагностика проблемных устройств (Samsung A52 и т.п., к которым
/// нет физического доступа): копит события — ошибки Flutter/Dart, зависшие
/// кадры, «мигание» клавиатурных инсетов — и раз в 20 секунд пишет последние
/// строки в clientLogs/{uid}. Читается сервером через tgSetup?action=clientlogs.
class DiagService {
  DiagService._();

  static final DiagService instance = DiagService._();

  final List<String> _lines = <String>[];
  Timer? _flush;
  String? _uid;
  bool _hooked = false;

  // Детект осцилляции клавиатуры: сколько раз менялся нижний инсет за 3 сек.
  double _lastInset = -1;
  final List<int> _insetEvents = <int>[];

  bool _startLogged = false;

  void start(String uid) {
    _uid = uid;
    if (_startLogged) return;
    _startLogged = true;
    if (!_hooked) {
      _hooked = true;

      final prevFlutter = FlutterError.onError;
      FlutterError.onError = (details) {
        log('ERR ${details.exceptionAsString().split('\n').first}');
        prevFlutter?.call(details);
      };

      final prevPlatform = WidgetsBinding.instance.platformDispatcher.onError;
      WidgetsBinding.instance.platformDispatcher.onError = (e, st) {
        log('DART ${e.toString().split('\n').first}');
        return prevPlatform?.call(e, st) ?? false;
      };

      // Зависшие кадры: билд+растр дольше 300 мс — приложение «дёргается».
      WidgetsBinding.instance.addTimingsCallback((timings) {
        for (final t in timings) {
          final ms = t.totalSpan.inMilliseconds;
          if (ms > 300) log('JANK кадр $ms мс');
        }
      });
    }
    _flush ??= Timer.periodic(const Duration(seconds: 20), (_) => _send());
    log('start ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  }

  /// Вызывается из MainShell.didChangeMetrics: ловит «мигание» клавиатуры
  /// (инсет прыгает вверх-вниз — клавиатура пытается открыться и прячется).
  void onMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final inset = views.first.viewInsets.bottom;
    if ((inset - _lastInset).abs() < 1) return;
    _lastInset = inset;
    final now = DateTime.now().millisecondsSinceEpoch;
    _insetEvents.add(now);
    _insetEvents.removeWhere((t) => now - t > 3000);
    if (_insetEvents.length >= 8) {
      log('IME-FLAP: ${_insetEvents.length} изменений инсета за 3с (тек=${inset.toStringAsFixed(0)})');
      _insetEvents.clear();
    }
  }

  void log(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    _lines.add('$ts $msg');
    if (_lines.length > 150) _lines.removeRange(0, _lines.length - 150);
  }

  Future<void> _send() async {
    final uid = _uid;
    if (uid == null || _lines.isEmpty) return;
    try {
      await FirebaseFirestore.instance.doc('clientLogs/$uid').set({
        'lines': List<String>.from(_lines),
        'os': Platform.operatingSystemVersion,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }
}
