import 'package:flutter_test/flutter_test.dart';

import 'package:crm/src/data/firestore_chat_repository.dart';
import 'package:crm/src/data/pending_match.dart';

/// Тесты сверки «летящих» пузырей (сообщение показано до ответа сервера)
/// с настоящими документами Firestore.
///
/// Жалоба менеджеров: «отправил сообщение — оно пропало и появилось только
/// через несколько секунд» (заметнее всего на медленных Android/Samsung).
/// Причина была здесь: подтверждённый документ не помечался занятым, и
/// следующий пузырь присваивал его себе, а сам скрывался раньше времени.
void main() {
  const me = 'manager-1';
  final base = DateTime(2026, 8, 17, 12, 0, 0);

  FsMessage doc(String id, DateTime at, {String dir = 'outbound', String? author = me}) => FsMessage(
        id: id,
        direction: dir,
        type: 'text',
        text: 'текст',
        contentUri: null,
        mediaUrl: null,
        status: 'sent',
        createdAt: at,
        isEdited: false,
        isDeleted: false,
        replyToText: null,
        authorId: author,
      );

  test('БАГ (регрессия): подтверждённый документ не должен гасить чужой пузырь', () {
    // A отправлено и подтверждено: функция вернула id, документ уже в чате.
    // B отправлено 2 секунды спустя, его документ ЕЩЁ не прилетел.
    final a = PendingMsg(text: 'A', at: base)..serverId = 'doc-a';
    final b = PendingMsg(text: 'B', at: base.add(const Duration(seconds: 2)));

    final waiting = waitingPending(
      loaded: [doc('doc-a', base.add(const Duration(seconds: 1)))],
      pending: [a, b],
      meUid: me,
      now: base.add(const Duration(seconds: 3)),
    );

    // Раньше B засчитывал себе doc-a (попадает в его 10-секундное окно)
    // и пропадал с экрана, пока летел его собственный документ.
    expect(waiting.map((p) => p.text), ['B']);
  });

  test('документ пришёл раньше ответа функции — пузырь гаснет, дубля нет', () {
    // Firestore обычно быстрее ответа Cloud Function: serverId ещё null,
    // но наш исходящий документ уже в переписке.
    final a = PendingMsg(text: 'A', at: base);

    final waiting = waitingPending(
      loaded: [doc('doc-a', base.add(const Duration(seconds: 1)))],
      pending: [a],
      meUid: me,
      now: base.add(const Duration(seconds: 2)),
    );

    expect(waiting, isEmpty);
  });

  test('две быстрые отправки, прилетел только первый документ — второй пузырь виден', () {
    final a = PendingMsg(text: 'A', at: base);
    final b = PendingMsg(text: 'B', at: base.add(const Duration(seconds: 1)));

    final waiting = waitingPending(
      loaded: [doc('doc-a', base.add(const Duration(milliseconds: 500)))],
      pending: [a, b],
      meUid: me,
      now: base.add(const Duration(seconds: 2)),
    );

    expect(waiting.map((p) => p.text), ['B']);
  });

  test('чужие сообщения пузырь не гасят: входящие и другого менеджера', () {
    final a = PendingMsg(text: 'A', at: base);

    final waiting = waitingPending(
      loaded: [
        doc('in-1', base.add(const Duration(seconds: 1)), dir: 'inbound', author: null),
        doc('out-2', base.add(const Duration(seconds: 1)), author: 'manager-2'),
      ],
      pending: [a],
      meUid: me,
      now: base.add(const Duration(seconds: 2)),
    );

    expect(waiting.map((p) => p.text), ['A']);
  });

  test('старый документ (отправлен до пузыря) не засчитывается', () {
    // Сообщение, ушедшее полминуты назад, не должно гасить свежий пузырь.
    final a = PendingMsg(text: 'A', at: base);

    final waiting = waitingPending(
      loaded: [doc('old', base.subtract(const Duration(seconds: 30)))],
      pending: [a],
      meUid: me,
      now: base.add(const Duration(seconds: 1)),
    );

    expect(waiting.map((p) => p.text), ['A']);
  });

  test('пузырь старше 2 минут не показывается (отправка потерялась)', () {
    final a = PendingMsg(text: 'A', at: base);

    final waiting = waitingPending(
      loaded: const [],
      pending: [a],
      meUid: me,
      now: base.add(const Duration(minutes: 3)),
    );

    expect(waiting, isEmpty);
  });

  test('часы телефона спешат: документ с серверным временем всё равно гасит пузырь по serverId', () {
    // На части Samsung время выставлено руками и уходит вперёд. Серверный
    // timestamp тогда «старше» локального createdAt, окно по времени не
    // срабатывает — но точное совпадение по id должно гасить пузырь всегда.
    final a = PendingMsg(text: 'A', at: base.add(const Duration(minutes: 1)))..serverId = 'doc-a';

    final waiting = waitingPending(
      loaded: [doc('doc-a', base)],
      pending: [a],
      meUid: me,
      now: base.add(const Duration(minutes: 1, seconds: 2)),
    );

    expect(waiting, isEmpty);
  });

  test('три отправки подряд: каждый документ достаётся своему пузырю по порядку', () {
    final a = PendingMsg(text: 'A', at: base);
    final b = PendingMsg(text: 'B', at: base.add(const Duration(seconds: 1)));
    final c = PendingMsg(text: 'C', at: base.add(const Duration(seconds: 2)));

    final waiting = waitingPending(
      loaded: [
        doc('doc-a', base.add(const Duration(milliseconds: 300))),
        doc('doc-b', base.add(const Duration(milliseconds: 1300))),
      ],
      pending: [c, a, b], // порядок в списке не важен
      meUid: me,
      now: base.add(const Duration(seconds: 3)),
    );

    expect(waiting.map((p) => p.text), ['C']);
  });
}
