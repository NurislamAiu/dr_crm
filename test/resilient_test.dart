import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:crm/src/data/stream_retry.dart';

void main() {
  test('resilient: обрыв подписки — переподключение без ошибки наверх', () async {
    var attempt = 0;
    Stream<int> create() {
      attempt++;
      if (attempt == 1) {
        // Первая подписка отдала значение и упала (как permission-denied).
        return Stream<int>.multi((c) {
          c.add(1);
          c.addError(StateError('permission-denied'));
          c.close();
        });
      }
      return Stream<int>.value(2);
    }

    final got = await resilient(create, retryEvery: const Duration(milliseconds: 10)).take(2).toList();
    expect(got, [1, 2]);
    expect(attempt, 2);
  });

  test('resilient: если не поднялось за окно — ошибка доходит до экрана', () async {
    Stream<int> create() => Stream<int>.error(StateError('down'));

    Object? err;
    try {
      await resilient(
        create,
        retryEvery: const Duration(milliseconds: 5),
        window: const Duration(milliseconds: 30),
      ).first;
    } catch (e) {
      err = e;
    }
    expect(err, isA<StateError>());
  });

  test('resilient: окно отсчитывается заново после каждых свежих данных', () async {
    var attempt = 0;
    Stream<int> create() {
      attempt++;
      return Stream<int>.multi((c) {
        c.add(attempt);
        Timer(const Duration(milliseconds: 15), () {
          c.addError(StateError('drop'));
          c.close();
        });
      });
    }

    // Окно 40 мс, но данные приходят каждые 15 мс — ошибка наверх не уходит.
    final got = await resilient(
      create,
      retryEvery: const Duration(milliseconds: 5),
      window: const Duration(milliseconds: 40),
    ).take(4).toList();
    expect(got, [1, 2, 3, 4]);
  });
}
