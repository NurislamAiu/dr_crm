import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/prank_service.dart';
import '../state/providers.dart';

/// Встроенная картинка розыгрыша: лежит в сборке, показывается мгновенно —
/// сети в момент шутки не нужно вообще.
const kPrankAsset = 'assets/prank/nolik.png';

/// Есть ли встроенная картинка в этой сборке (файл кладут в assets/prank/).
Future<bool> prankAssetExists() async {
  try {
    await rootBundle.load(kPrankAsset);
    return true;
  } catch (_) {
    return false;
  }
}

/// Обёртка над всем приложением: показывает картинку-розыгрыш поверх любого
/// экрана, что бы менеджер сейчас ни делал.
///
/// Стоит НАД навигатором (в builder MaterialApp), поэтому не зависит от того,
/// какой экран открыт, и не ломает его состояние. Уходит сама через заданные
/// секунды или по тапу. Звука нет — только картинка.
class PrankHost extends ConsumerStatefulWidget {
  const PrankHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PrankHost> createState() => _PrankHostState();
}

class _PrankHostState extends ConsumerState<PrankHost> {
  PrankItem? _showing;
  Timer? _timer;

  /// Что уже показали в этом запуске — повторно не показываем.
  final Set<String> _seen = {};

  /// Картинку греем заранее (при запуске приложения), чтобы в момент шутки
  /// не ждать загрузку и не показать чёрный экран.
  String? _warmed;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _warm(String? url) {
    if (url == null || url.isEmpty || url == _warmed || !mounted) return;
    _warmed = url;
    precacheImage(NetworkImage(url), context).catchError((_) {});
  }

  Future<void> _show(PrankItem item) async {
    if (_seen.contains(item.id) || !item.isFresh) return;
    _seen.add(item.id);

    // Встроенная картинка — сразу. Загруженную греем и показываем только
    // если она реально загрузилась: иначе вместо шутки будет чёрный экран.
    if (!item.isAsset) {
      var ok = true;
      await precacheImage(NetworkImage(item.url), context, onError: (_, _) => ok = false);
      if (!ok || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _showing = item);
    _timer?.cancel();
    _timer = Timer(Duration(seconds: item.seconds), _hide);
  }

  void _hide() {
    _timer?.cancel();
    if (mounted && _showing != null) setState(() => _showing = null);
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(appConfigProvider).userId;
    if (uid != null && uid.isNotEmpty) {
      ref.listen(prankProvider(uid), (_, next) {
        final item = next.value;
        if (item != null) _show(item);
      });
      // Заранее скачиваем текущую картинку розыгрыша.
      ref.listen(prankImageProvider, (_, next) => _warm(next.value));
      _warm(ref.read(prankImageProvider).value);
    }

    final item = _showing;
    // Число детей у Stack постоянное: если добавлять/убирать слой, Flutter
    // на перестройке дерева «переселяет» навигатор приложения и ругается
    // ассертом Overlay (_dependents.isEmpty). Пустой слой ничего не стоит.
    return Stack(children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          ignoring: item == null,
          child: item == null
              ? const SizedBox.shrink()
              // Фон прозрачный: картинка появляется прямо поверх экрана, на
              // котором менеджер работает. Тап по любому месту — закрыть.
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _hide,
                  child: RepaintBoundary(
                    child: item.isAsset
                        ? Image.asset(kPrankAsset, fit: BoxFit.contain, width: double.infinity, height: double.infinity)
                        : Image.network(
                            item.url,
                            fit: BoxFit.contain,
                            width: double.infinity,
                            height: double.infinity,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                  ),
                ),
        ),
      ),
    ]);
  }
}
