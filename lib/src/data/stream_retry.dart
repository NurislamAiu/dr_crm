import 'dart:async';

/// Живучий поток Firestore.
///
/// Подписка Firestore при ошибке (нет сети, обновились правила, протух токен)
/// не восстанавливается сама — экран навсегда остаётся с «Ошибка». Здесь мы
/// молча пересоздаём подписку и отдаём ошибку наверх, только если за [window]
/// так и не удалось подключиться. Пока идут попытки, экран показывает
/// последние загруженные данные, а не ошибку.
Stream<T> resilient<T>(
  Stream<T> Function() create, {
  Duration retryEvery = const Duration(seconds: 4),
  Duration window = const Duration(seconds: 30),
}) async* {
  var deadline = DateTime.now().add(window);
  while (true) {
    try {
      await for (final value in create()) {
        // Данные пришли — отсчёт окна начинается заново.
        deadline = DateTime.now().add(window);
        yield value;
      }
      return; // поток закрылся штатно
    } catch (e) {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(retryEvery);
    }
  }
}
