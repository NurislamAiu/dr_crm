import 'dart:async';

import 'diag_service.dart';

/// Живучий поток Firestore.
///
/// Подписка Firestore при ошибке (нет сети, обновились правила, протух токен)
/// не восстанавливается сама — экран навсегда остаётся с «Ошибка». Здесь мы
/// молча пересоздаём подписку и отдаём ошибку наверх, только если за [window]
/// так и не удалось подключиться. Пока идут попытки, экран показывает
/// последние загруженные данные, а не ошибку.
Stream<T> resilient<T>(
  Stream<T> Function() create, {
  Duration retryEvery = const Duration(milliseconds: 300),
  Duration window = const Duration(seconds: 30),
}) async* {
  var deadline = DateTime.now().add(window);
  // Пауза растёт: первая попытка почти мгновенная, дальше реже. Раньше пауза
  // была фиксированной (4 секунды), и одна сорвавшаяся подписка означала
  // четыре секунды пустой крутилки — на телефоне это читается как «зависло».
  var pause = retryEvery;
  while (true) {
    try {
      await for (final value in create()) {
        // Данные пришли — отсчёт окна и паузы начинается заново.
        deadline = DateTime.now().add(window);
        pause = retryEvery;
        yield value;
      }
      return; // поток закрылся штатно
    } catch (e) {
      // В удалённый журнал: «у менеджера пусто» иначе не диагностировать —
      // resilient глотает ошибки молча, и телефон снаружи выглядит здоровым.
      DiagService.instance.log('STREAM ошибка: $e');
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(pause);
      final next = pause * 2;
      pause = next > const Duration(seconds: 4) ? const Duration(seconds: 4) : next;
    }
  }
}
