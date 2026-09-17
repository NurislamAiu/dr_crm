import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'voice_playback.dart';

/// Единственный плеер голосовых на всё приложение.
///
/// Раньше каждый пузырь голосового держал СВОЙ AudioPlayer внутри своего
/// State — из этого росли сразу три бага:
///  • прокрутил переписку — список выгрузил ушедшую за экран строку, её
///    State умер и унёс с собой играющий звук;
///  • пришло новое сообщение — строки пересоздались, звук оборвался;
///  • два пузыря могли играть одновременно, друг о друге не зная.
///
/// Теперь звуком владеет этот синглтон: пузыри — только «пульты», которые
/// показывают его состояние и шлют команды. Пузырь может умирать и
/// рождаться сколько угодно — воспроизведение продолжается, а вернувшись к
/// нему, менеджер видит живой прогресс.
class VoiceController extends ChangeNotifier {
  VoiceController._();
  static final VoiceController I = VoiceController._();

  AudioPlayer? _player;

  /// Ссылка играющего (или поставленного на паузу) голосового.
  String? url;

  /// Файл ещё готовится к воспроизведению (скачивается/буферизуется).
  bool loading = false;

  /// Скорость — общая на все голосовые: менеджер, слушающий на 1.5×, хочет
  /// так слушать всё, а не разгонять каждый пузырь заново.
  double speed = 1;

  bool get playing => _player?.playing ?? false;

  /// Активен ли этот пузырь (он «владелец» текущего звука).
  bool isCurrent(String u) => url == u;

  /// Плеер для подписки на позицию — только владельцу.
  AudioPlayer? playerOf(String u) => url == u ? _player : null;

  /// Нажатие play/pause на пузыре [u]. Возвращает false, если файл не
  /// удалось открыть — пузырь покажет ошибку.
  Future<bool> toggle(String u) async {
    final p = _player;
    if (url == u && p != null) {
      if (p.playing) {
        await p.pause();
      } else {
        if (p.processingState == ProcessingState.completed) {
          await p.seek(Duration.zero);
        }
        p.play();
      }
      notifyListeners();
      return true;
    }
    return _startNew(u);
  }

  Future<bool> _startNew(String u) async {
    // Старый звук гасим сразу: пока новый файл грузится, двух голосов нет.
    final old = _player;
    _player = null;
    old?.dispose();

    url = u;
    loading = true;
    notifyListeners();

    // Режим воспроизведения: после записи голосового сессия остаётся
    // «разговорной», и звук уходил в тихий динамик у уха.
    await ensurePlaybackSession();
    final player = AudioPlayer();
    try {
      await player.setUrl(u);
      if (speed != 1) await player.setSpeed(speed);
    } catch (_) {
      await player.dispose();
      if (url == u) {
        url = null;
        loading = false;
        notifyListeners();
      }
      return false;
    }
    // Пока грузились, могли нажать play на другом пузыре — не мешаем ему.
    if (url != u) {
      await player.dispose();
      return true;
    }
    _player = player;
    loading = false;
    // Пузыри перерисовываются по каждому изменению состояния плеера:
    // само воспроизведение, конец файла, докачка.
    player.playerStateStream.listen((_) => notifyListeners());
    player.play();
    notifyListeners();
    return true;
  }

  /// Перемотка в долю [fraction] файла [u]. Чужой пузырь сначала становится
  /// владельцем (его файл загружается), потом мотается.
  Future<void> seekTo(String u, double fraction) async {
    if (url != u || _player == null) {
      final ok = await _startNew(u);
      if (!ok) return;
    }
    final p = _player;
    final dur = p?.duration;
    if (p == null || dur == null) return;
    await p.seek(dur * fraction.clamp(0.0, 1.0));
    notifyListeners();
  }

  /// Скорость по кругу: 1 → 1.5 → 2 → 1.
  Future<void> cycleSpeed() async {
    speed = switch (speed) { 1.0 => 1.5, 1.5 => 2.0, _ => 1.0 };
    await _player?.setSpeed(speed);
    notifyListeners();
  }

  /// Полная остановка (крестик на мини-панели).
  Future<void> stop() async {
    final p = _player;
    _player = null;
    url = null;
    loading = false;
    notifyListeners();
    await p?.dispose();
  }
}
