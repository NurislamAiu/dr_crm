import 'firestore_chat_repository.dart';

/// Сверка «летящих» пузырей с настоящими документами Firestore.
///
/// Сообщение менеджера показывается в чате МГНОВЕННО — раньше, чем ответит
/// Cloud Function и прилетит документ из Firestore. Такой пузырь надо убрать
/// ровно в тот момент, когда его настоящий документ появился в переписке:
/// раньше — сообщение «исчезает» на секунды, позже — двоится.
///
/// Логика вынесена из экрана в чистую функцию, потому что именно здесь жил
/// баг «отправил — сообщение пропало и появилось только через несколько
/// секунд» (особенно заметно на медленных Android): подтверждённый сервером
/// документ не помечался занятым, и следующий пузырь ошибочно засчитывал его
/// себе — а сам оставался скрытым, пока его документ ещё летел.
class PendingMsg {
  PendingMsg({
    required this.text,
    this.replyToText,
    this.type = 'text',
    this.localPath,
    this.fileName,
    DateTime? at,
  })  : localId = 'local_${(at ?? DateTime.now()).microsecondsSinceEpoch}',
        createdAt = at ?? DateTime.now();

  final String localId;
  final String text;
  final String? replyToText;
  final DateTime createdAt;

  /// text | audio | image | document — вид пузыря до подтверждения.
  final String type;

  /// Файл на устройстве: превью показываем с него, пока идёт загрузка.
  final String? localPath;
  final String? fileName;

  /// id документа, который вернула Cloud Function (пришёл — пузырь убираем).
  String? serverId;
}

/// Пузыри, которые ЕЩЁ нужно показывать поверх загруженной переписки.
///
/// Порядок сверки важен:
///  1. Сначала точные совпадения: функция вернула id, документ с этим id уже
///     в переписке. Документ помечается занятым — чтобы чужой пузырь не
///     присвоил его себе по совпадению времени.
///  2. Остальные (ответ функции ещё не пришёл) — по времени: документ обычно
///     прилетает из Firestore РАНЬШЕ ответа функции, и без этой сверки
///     сообщение задваивалось. Окно в 10 секунд назад — на расхождение часов
///     телефона с сервером. Сверять по тексту нельзя: WhatsApp-вариации
///     меняют текст при отправке.
List<PendingMsg> waitingPending({
  required List<FsMessage> loaded,
  required List<PendingMsg> pending,
  required String? meUid,
  required DateTime now,
}) {
  final used = <String>{};
  final unconfirmed = <PendingMsg>[];
  for (final p in pending) {
    // Старше 2 минут — считаем потерянным (ошибка сети и т.п.), не показываем.
    if (now.difference(p.createdAt) > const Duration(minutes: 2)) continue;
    final sid = p.serverId;
    if (sid != null && loaded.any((m) => m.id == sid)) {
      used.add(sid);
      continue;
    }
    unconfirmed.add(p);
  }

  unconfirmed.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final waiting = <PendingMsg>[];
  for (final p in unconfirmed) {
    String? hit;
    for (final m in loaded) {
      if (used.contains(m.id) || !m.isOutbound || m.authorId != meUid) continue;
      final t = m.createdAt;
      if (t == null || t.isBefore(p.createdAt.subtract(const Duration(seconds: 10)))) continue;
      hit = m.id;
      break;
    }
    if (hit != null) {
      used.add(hit);
      continue;
    }
    waiting.add(p);
  }
  return waiting;
}
