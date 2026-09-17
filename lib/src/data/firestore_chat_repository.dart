import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Фразы, которыми менеджер обычно завершает разговор, когда клиент уже
/// согласился («вы записаны», «ждём вас», «договорились»…). Список зеркалит
/// CLOSING_PHRASES/CLOSING_SHORT в functions/src/follow-up.ts — держите их
/// в согласии, если правите один список, поправьте и второй.
const _closingPhrases = [
  'ждем вас', 'будем ждать', 'будем вас ждать', 'ждем',
  'до встречи', 'до свидания', 'всего доброго',
  'хорошего дня', 'хорошего вечера', 'доброго пути',
  'договорились', 'вы записаны', 'записали вас', 'записал вас', 'записала вас',
  'приходите', 'подходите', 'приезжайте',
  'рады будем', 'обращайтесь', 'на связи',
];
const _closingShort = [
  'хорошо', 'ок', 'окей', 'спасибо', 'спасиба', 'рахмет',
  'пожалуйста', 'не за что', 'отлично', 'супер', 'принято', 'добро',
];

bool _isClosingMessage(String raw) {
  final t = raw
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^a-zа-я0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  if (t.isEmpty) return false;
  if (_closingPhrases.any((p) => t.contains(p))) return true;
  if (t.length <= 40 && _closingShort.any((w) => t.contains(w))) return true;
  return false;
}

/// Диалог из Firestore (коллекция conversations, ключ = chatId).
/// Telegram-чаты живут в той же коллекции с ключом `tg_<tg_id>`.
class FsConversation {
  FsConversation({
    required this.id,
    required this.name,
    required this.phone,
    required this.preview,
    required this.lastMessageAt,
    required this.unreadCount,
    this.lastOutbound = false,
    this.lastAuthorId,
    this.lastAuthorName,
    this.manualUnread = false,
    this.blocked = false,
    this.responsibleId,
    this.privateOwnerUid,
    this.responsibleName,
    this.typingUid,
    this.typingName,
    this.typingAt,
    this.viewers = const {},
    this.topic,
    this.lastInboundAt,
    this.wantsAppointmentAt,
    this.aiSuggestion,
  });
  final String id;
  final String name;
  final String? phone;
  final String? preview;
  final DateTime? lastMessageAt;
  final int unreadCount;

  /// Последнее сообщение — исходящее (ответ менеджера).
  final bool lastOutbound;

  /// uid менеджера, ответившего последним ('auto' — автоответчик).
  final String? lastAuthorId;

  /// Имя автора из Wazzup (ответ из интерфейса Wazzup/WhatsApp).
  final String? lastAuthorName;

  /// Отмечен непрочитанным вручную (как в WhatsApp).
  final bool manualUnread;

  /// Заблокирован менеджером: скрыт из списка, без пушей и автоответов.
  final bool blocked;

  /// Ответственный менеджер (Telegram): null — чат «свободен».
  final String? responsibleId;
  final String? responsibleName;

  /// Личный чат владельца: он написал первым тому, кто нам никогда не писал.
  /// Такие переписки видит только сам владелец — у остальных их нет в списке
  /// и по ним не приходят пуши. Ставится сервером один раз и не снимается.
  final String? privateOwnerUid;

  /// Кто сейчас печатает в этом чате (heartbeat из приложения).
  final String? typingUid;
  final String? typingName;
  final DateTime? typingAt;

  /// Тема обращения, размеченная сервером по входящему тексту.
  /// 'training' — писали про обучение у доктора, 'supplements' — про БАДы.
  final String? topic;

  bool get isTraining => topic == 'training';

  /// Обращение по БАДам: заказ добавок, а не запись на приём.
  bool get isSupplements => topic == 'supplements';

  /// Просили перезвонить/созвониться — клиент ждёт звонка, а не сообщения.
  bool get isCall => topic == 'call';

  /// У темы своя вкладка — в общий поток пациентов такой чат не попадает.
  /// Своя вкладка — только у обучения и БАДов. Тема «звонок» осталась в
  /// старых документах, но вкладки у неё больше нет: такой чат живёт в своём
  /// мессенджере как обычный пациентский.
  bool get hasOwnTab => isTraining || isSupplements;

  /// Момент последнего ВХОДЯЩЕГО сообщения — точка отсчёта, сколько клиент
  /// уже ждёт ответа.
  final DateTime? lastInboundAt;

  /// Когда клиент в последний раз явно спрашивал про запись/приём («хочу
  /// записаться», «когда можно прийти»…). Сервер обновляет метку на каждое
  /// такое сообщение — старое обращение само перестаёт считаться «горячим».
  final DateTime? wantsAppointmentAt;

  /// Бейдж «Ждёт записи» временный: висит [_wantsAppointmentWindow] с
  /// момента последнего такого сообщения, потом гаснет сам — чат, про
  /// который спросили три дня назад и забыли, не должен маячить вечно.
  static const _wantsAppointmentWindow = Duration(hours: 24);
  bool get wantsAppointment {
    final at = wantsAppointmentAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < _wantsAppointmentWindow;
  }

  /// Последнее сообщение — от менеджера и звучит как завершение сделки
  /// («вы записаны», «ждём вас», «договорились») — похоже, разговор уже
  /// закрыт, а лида менеджер сохранить забыл. Тот же список фраз, что и у
  /// серверного догрева (functions/src/follow-up.ts), — там он решает,
  /// не спрашивать ли «ещё думаете?» человеку, который уже согласился.
  bool get looksLikeUnsavedLead => lastOutbound && _isClosingMessage(preview ?? '');

  /// Черновик ответа от ИИ (Claude Haiku) на первое сообщение нового чата —
  /// менеджер видит его в переписке и решает: отправить, поправить или
  /// скрыть. null — подсказки нет (выключено, чат не новый или уже решили).
  final String? aiSuggestion;

  /// Чат Telegram (отвечаем через Bot API, а не Wazzup).
  bool get isTelegram => id.startsWith('tg_');

  /// Сколько минут клиент ждёт ответа прямо сейчас. null — ждать нечего:
  /// либо последнее слово за менеджером, либо чат уже прочитан/заблокирован.
  int? waitingMinutes() {
    if (blocked || lastOutbound) return null;
    if (unreadCount <= 0 && !manualUnread) return null;
    final at = lastInboundAt ?? lastMessageAt;
    if (at == null) return null;
    final m = DateTime.now().difference(at).inMinutes;
    return m < 0 ? 0 : m;
  }

  /// «Отвечает [имя]» — печатает ДРУГОЙ менеджер и отметка свежая.
  /// Главная защита от двойных ответов.
  bool typingByOther(String? myUid) {
    if (typingUid == null || typingUid == myUid) return false;
    final at = typingAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < const Duration(seconds: 12);
  }

  /// Кто сейчас находится в этом чате: uid → имя, последний heartbeat и
  /// момент входа. Пишется приложением при открытом экране переписки.
  final Map<String, ({String name, DateTime? at, DateTime? since})> viewers;

  /// ДРУГОЙ менеджер сейчас в чате (heartbeat свежий). Если таких несколько,
  /// возвращается вошедший раньше всех — он и «владеет» разговором.
  ({String name, DateTime? since})? viewerOther(String? myUid) {
    ({String name, DateTime? since})? best;
    final now = DateTime.now();
    for (final e in viewers.entries) {
      if (e.key == myUid) continue;
      final at = e.value.at;
      // 45 сек: heartbeat идёт раз в 20 сек, два пропуска — человек ушёл
      // (закрыл приложение, пропала сеть), замок снимается сам.
      if (at == null || now.difference(at) > const Duration(seconds: 45)) continue;
      if (best == null ||
          (e.value.since ?? DateTime(0)).isBefore(best.since ?? DateTime(0))) {
        best = (name: e.value.name, since: e.value.since);
      }
    }
    return best;
  }

  static FsConversation fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final typing = d['typing'] is Map ? (d['typing'] as Map).cast<String, dynamic>() : null;
    final rawViewers =
        d['viewers'] is Map ? (d['viewers'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    return FsConversation(
      viewers: {
        for (final e in rawViewers.entries)
          if (e.value is Map)
            e.key: (
              name: (((e.value as Map)['name'] as String?) ?? '').trim(),
              at: ((e.value as Map)['at'] as Timestamp?)?.toDate(),
              since: ((e.value as Map)['since'] as Timestamp?)?.toDate(),
            ),
      },
      id: doc.id,
      name: (d['name'] ?? doc.id) as String,
      phone: d['phone'] as String?,
      preview: d['lastMessagePreview'] as String?,
      lastMessageAt: (d['lastMessageAt'] as Timestamp?)?.toDate(),
      unreadCount: (d['unreadCount'] as num?)?.toInt() ?? 0,
      lastOutbound: d['lastOutbound'] == true,
      lastAuthorId: d['lastAuthorId'] as String?,
      lastAuthorName: d['lastAuthorName'] as String?,
      manualUnread: d['manualUnread'] == true,
      blocked: d['blocked'] == true,
      responsibleId: d['responsibleId'] as String?,
      privateOwnerUid: d['privateOwnerUid'] as String?,
      responsibleName: d['responsibleName'] as String?,
      lastInboundAt: (d['lastInboundAt'] as Timestamp?)?.toDate(),
      wantsAppointmentAt: (d['wantsAppointmentAt'] as Timestamp?)?.toDate(),
      aiSuggestion: (d['aiSuggestion'] as String?)?.trim().isEmpty == true ? null : d['aiSuggestion'] as String?,
      typingUid: typing?['uid'] as String?,
      typingName: typing?['name'] as String?,
      typingAt: (typing?['at'] as Timestamp?)?.toDate(),
      topic: d['topic'] as String?,
    );
  }
}

/// Сообщение из Firestore (коллекция messages, ключ = messageId).
class FsMessage {
  FsMessage({
    required this.id,
    required this.direction,
    required this.type,
    required this.text,
    required this.contentUri,
    required this.mediaUrl,
    this.fileName,
    this.mediaContentType,
    required this.status,
    required this.createdAt,
    required this.isEdited,
    required this.isDeleted,
    required this.replyToText,
    this.authorId,
    this.authorName,
    this.callResult,
    this.isBroadcast = false,
  });
  final String id;
  final String direction; // inbound | outbound
  final String type;
  final String? text;
  final String? contentUri;
  final String? mediaUrl; // durable-ссылка (Storage), fallback contentUri
  /// Имя файла (для документов Telegram, напр. «чек.pdf»).
  final String? fileName;
  /// MIME-тип медиа (application/pdf и т.п.) — для выбора просмотрщика.
  final String? mediaContentType;
  final String status;
  final DateTime? createdAt;
  final bool isEdited;
  final bool isDeleted;
  final String? replyToText;

  /// uid менеджера-отправителя ('auto' — автоответчик).
  final String? authorId;

  /// Имя автора из Wazzup (когда отвечали не из нашего приложения).
  final String? authorName;

  /// Результат звонка: answered | noAnswer (для type == 'call').
  final String? callResult;

  /// Сообщение ушло рассылкой.
  final bool isBroadcast;

  /// Текст автоматически уникализирован перед отправкой в WhatsApp
  /// (тот же шаблон уже уходил другим — иначе номер банят за повторы).
  bool textVaried = false;

  /// Почему сообщение придержано: hour/day — лимит темпа, mass — одинаковый
  /// текст многим, window — WABA ждёт ответа клиента (24-часовое окно).
  String? queueReason;

  /// Текст ошибки от Wazzup (для status == error).
  String? statusError;

  bool get isOutbound => direction == 'outbound';
  String? get media => mediaUrl ?? contentUri;

  static FsMessage fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return FsMessage(
      id: doc.id,
      direction: (d['direction'] ?? 'inbound') as String,
      type: (d['type'] ?? 'text') as String,
      text: d['text'] as String?,
      contentUri: d['contentUri'] as String?,
      mediaUrl: d['mediaUrl'] as String?,
      fileName: d['fileName'] as String?,
      mediaContentType: d['mediaContentType'] as String?,
      status: (d['status'] ?? '') as String,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      isEdited: d['isEdited'] == true,
      isDeleted: d['isDeleted'] == true,
      replyToText: d['replyToText'] as String?,
      authorId: d['authorId'] as String?,
      authorName: d['authorName'] as String?,
      callResult: d['callResult'] as String?,
      isBroadcast: d['isBroadcast'] == true,
    )
      ..queueReason = d['queueReason'] as String?
      ..statusError = d['statusError'] as String?
      ..textVaried = d['textVaried'] == true;
  }
}

/// Показывать вкладку WhatsApp (Wazzup) рядом с Telegram. Выключить = список
/// снова станет только телеграмным (история WhatsApp сохранится).
const bool kShowWhatsAppChats = true;

/// Чаты поверх Firestore + отправка через Cloud Functions.
/// Маршрутизация транспорта — по ключу диалога: `tg_...` → Telegram Bot API,
/// иначе — прежний путь через Wazzup.
class FirestoreChatRepository {
  FirestoreChatRepository({FirebaseFirestore? db, FirebaseFunctions? functions})
      : _db = db ?? FirebaseFirestore.instance,
        _injectedFunctions = functions;

  final FirebaseFirestore _db;
  final FirebaseFunctions? _injectedFunctions;

  // Лениво: в превью-сборке (fake Firestore, без Firebase.initializeApp)
  // обращение к FirebaseFunctions в конструкторе роняло экран.
  FirebaseFunctions? _cachedFunctions;
  FirebaseFunctions get _functions =>
      _injectedFunctions ?? (_cachedFunctions ??= FirebaseFunctions.instanceFor(region: 'europe-west1'));

  // Анти-бан: минимальный интервал между исходящими (по всем чатам).
  // Быстрые серии сообщений растягиваются, чтобы WhatsApp не считал это спамом.
  static const Duration _minGap = Duration(seconds: 3);
  DateTime? _lastSendAt;

  Future<void> _throttle() async {
    final now = DateTime.now();
    if (_lastSendAt != null) {
      final elapsed = now.difference(_lastSendAt!);
      if (elapsed < _minGap) {
        final wait = _minGap - elapsed;
        await Future.delayed(wait);
      }
    }
    _lastSendAt = DateTime.now();
  }

  Stream<List<FsConversation>> watchConversations() {
    // limit(500): коллекция растёт бесконечно, без лимита каждый запуск
    // приложения читал бы ВСЕ диалоги (деньги за reads). 500 свежих хватает.
    return _db
        .collection('conversations')
        .orderBy('lastMessageAt', descending: true)
        .limit(500)
        .snapshots()
        .map((s) {
      final list = s.docs.map(FsConversation.fromDoc).toList();
      if (kShowWhatsAppChats) return list;
      return list.where((c) => c.isTelegram).toList();
    });
  }

  /// Написания номера, под которыми его стоит искать.
  ///
  /// В базе номер лежит цифрами без «+» (`79899520222`), имя телеграм-чата с
  /// известным номером — «+79899520222». Менеджер же набирает как привык:
  /// «8 989…», «+7 989…» или вовсе без кода страны. Раньше искалось ровно то,
  /// что набрано, — и номер, записанный через 8, не находился никогда.
  static List<String> phoneSearchVariants(String digits) {
    if (digits.length < 4) return const [];
    final out = <String>{digits};
    if (digits.startsWith('8')) {
      out.add('7${digits.substring(1)}'); // 8 989… → 7 989…
    } else if (!digits.startsWith('7')) {
      out.add('7$digits'); // 989… → 7 989… (набрали без кода страны)
    }
    return out.toList();
  }

  /// Поиск диалогов ПО ВСЕЙ базе, а не только по 500 загруженным.
  ///
  /// Список чатов держит 500 свежих — старый диалог (написал неделю назад)
  /// в него не попадает, и поиск по номеру возвращал «ничего не найдено»,
  /// хотя чат есть. Ищем префиксными запросами по номеру и по имени, и
  /// каждый — во всех написаниях номера (см. [phoneSearchVariants]).
  Future<List<FsConversation>> searchConversations(String query) async {
    final q = query.trim();
    final digits = q.replaceAll(RegExp(r'\D'), '');
    // Номер ищем от 4 цифр, имя — от 3 букв.
    if (q.length < 3 && digits.length < 4) return const [];
    final found = <String, FsConversation>{};

    Future<void> run(Query<Map<String, dynamic>> query) async {
      try {
        final snap = await query.limit(20).get();
        for (final d in snap.docs) {
          found[d.id] = FsConversation.fromDoc(d);
        }
      } catch (_) {
        // Нет индекса или нет прав — просто не добавляем результаты.
      }
    }

    // Префикс: «всё, что начинается на value». Ищем по началу номера, а не
    // по полному совпадению, — тогда находится и «77015», и весь номер.
    Query<Map<String, dynamic>> prefix(String field, String value) => _db
        .collection('conversations')
        .orderBy(field)
        .startAt([value])
        .endAt(['$value']);

    for (final p in phoneSearchVariants(digits)) {
      await run(prefix('phone', p));
      await run(prefix('name', '+$p'));
    }
    // По имени — только если в запросе есть буквы: у «77015…» искать имя
    // незачем, это лишние чтения. Firestore сравнивает строки побайтово,
    // поэтому «иван» и «Иван» — разные диапазоны: пробуем оба написания.
    if (q.length >= 3 && RegExp(r'\p{L}', unicode: true).hasMatch(q)) {
      final cap = q[0].toUpperCase() + q.substring(1);
      final low = q[0].toLowerCase() + q.substring(1);
      await run(prefix('name', q));
      if (cap != q) await run(prefix('name', cap));
      if (low != q) await run(prefix('name', low));
    }

    final list = found.values.toList()
      ..sort((a, b) => (b.lastMessageAt ?? DateTime(0)).compareTo(a.lastMessageAt ?? DateTime(0)));
    return list;
  }

  /// Поиск перебором по всей коллекции: читает диалоги от свежих к старым
  /// страницами и сравнивает уже на клиенте.
  ///
  /// Нужен там, где префиксные запросы бессильны: набраны ПОСЛЕДНИЕ цифры
  /// номера, кусок из середины или часть имени не с начала. Стоит тысячи
  /// чтений, поэтому запускается только вручную — кнопкой «Искать по всей
  /// базе», когда быстрый поиск ничего не нашёл.
  Future<List<FsConversation>> deepSearchConversations(
    String query, {
    int maxDocs = 6000,
  }) async {
    final q = query.trim().toLowerCase();
    final digits = q.replaceAll(RegExp(r'\D'), '');
    if (q.length < 3 && digits.length < 4) return const [];
    // Для «хвоста» номера вариант с добавленной семёркой не нужен и мешает:
    // ищем ровно набранные цифры, а также 8→7 для полного номера.
    final variants = <String>{
      if (digits.length >= 4) digits,
      if (digits.startsWith('8') && digits.length >= 10) '7${digits.substring(1)}',
    }.toList();
    final out = <FsConversation>[];
    DocumentSnapshot<Map<String, dynamic>>? cursor;
    var read = 0;

    while (read < maxDocs) {
      var page = _db
          .collection('conversations')
          .orderBy('lastMessageAt', descending: true)
          .limit(500);
      if (cursor != null) page = page.startAfterDocument(cursor);
      final snap = await page.get();
      if (snap.docs.isEmpty) break;
      read += snap.docs.length;
      cursor = snap.docs.last;
      for (final d in snap.docs) {
        final c = FsConversation.fromDoc(d);
        // Цифры берём и из номера, и из имени: у телеграм-чатов номер
        // попадает в имя («+7989…»), а поле phone может быть пустым.
        final onlyDigits = '${c.phone ?? ''} ${c.name}'.replaceAll(RegExp(r'\D'), '');
        if (variants.any(onlyDigits.contains) || c.name.toLowerCase().contains(q)) {
          out.add(c);
        }
      }
      if (snap.docs.length < 500) break;
    }
    out.sort((a, b) => (b.lastMessageAt ?? DateTime(0)).compareTo(a.lastMessageAt ?? DateTime(0)));
    return out;
  }

  /// Живой документ ОДНОГО диалога. Экран чата подписывается только на себя:
  /// подписка на весь список означала ребилд чата при каждом событии в любом
  /// чате (сообщения и «печатает…» коллег каждые пару секунд в рабочий час) —
  /// на части Android из-за этого не показывалась клавиатура.
  Stream<FsConversation?> watchConversation(String conversationId) => _db
      .collection('conversations')
      .doc(conversationId)
      .snapshots()
      .map((d) => d.data() == null ? null : FsConversation.fromDoc(d));

  /// Последний снимок переписки по чату. Держим в памяти, чтобы повторное
  /// открытие чата показывало сообщения сразу: подписка Firestore на Android
  /// иногда «просыпается» несколько секунд, и всё это время экран был пустым
  /// с одной крутилкой.
  final Map<String, List<FsMessage>> _lastMessages = {};

  Stream<List<FsMessage>> watchMessages(String conversationId) async* {
    final cached = _lastMessages[conversationId];
    if (cached != null) yield cached;
    yield* _watchMessagesLive(conversationId);
  }

  Stream<List<FsMessage>> _watchMessagesLive(String conversationId) {
    // Последние 100 (desc + limit), затем разворот для показа снизу вверх.
    return _db
        .collection('messages')
        .where('conversationId', isEqualTo: conversationId)
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
        .map((s) {
      final list = s.docs.map(FsMessage.fromDoc).toList().reversed.toList();
      // Кэш ограничиваем: 30 последних чатов хватает на смену.
      if (_lastMessages.length > 30) _lastMessages.clear();
      _lastMessages[conversationId] = list;
      return list;
    });
  }

  Future<void> markRead(String conversationId) {
    return _db
        .collection('conversations')
        .doc(conversationId)
        .set({'unreadCount': 0, 'manualUnread': false}, SetOptions(merge: true));
  }

  /// Записать звонок менеджера в переписку (внутренняя отметка — клиенту
  /// ничего не уходит). [result]: answered | noAnswer.
  Future<void> logCall({
    required String chatId,
    required String result,
    required String authorId,
    required String authorName,
  }) async {
    await _db.collection('messages').add({
      'conversationId': chatId,
      'chatId': chatId,
      'direction': 'outbound',
      'type': 'call',
      'callResult': result,
      'authorId': authorId,
      'authorName': authorName,
      'isInternal': true, // не отправлялось в WhatsApp
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Отметить чат непрочитанным вручную (как в WhatsApp) — бейдж вернётся,
  /// пока чат снова не откроют.
  Future<void> markUnread(String conversationId) {
    return _db
        .collection('conversations')
        .doc(conversationId)
        .set({'manualUnread': true}, SetOptions(merge: true));
  }

  /// Отправка текста через Cloud Function. [conversationId] с префиксом
  /// `tg_` уходит в Telegram (tgSendMessage), иначе — прежний путь Wazzup.
  /// [refMessageId] — ответ (цитата) на сообщение.
  ///
  /// Возвращает id созданного сообщения — по нему экран чата убирает
  /// «оптимистичный» пузырь, показанный сразу после нажатия «отправить».
  /// Клиентской паузы здесь нет: темпом отправки управляет сервер (очередь).
  Future<String?> sendText({
    required String phone,
    required String text,
    String? conversationId,
    String? name,
    String? refMessageId,
    String? replyToText,
    /// WhatsApp Business API: менеджер подтвердил отправку приглашения
    /// шаблоном, когда клиент молчит больше 24 часов.
    bool sendOpener = false,
  }) async {
    if (conversationId != null && conversationId.startsWith('tg_')) {
      final data = <String, dynamic>{'conversationId': conversationId, 'text': text};
      if (refMessageId != null) data['refMessageId'] = refMessageId;
      if (replyToText != null) data['replyToText'] = replyToText;
      final r = await _functions.httpsCallable('tgSendMessage').call<Map<String, dynamic>>(data);
      return r.data['messageId'] as String?;
    }
    final callable = _functions.httpsCallable('sendMessage');
    final data = <String, dynamic>{'phone': phone, 'text': text};
    if (name != null) data['name'] = name;
    if (refMessageId != null) data['refMessageId'] = refMessageId;
    if (replyToText != null) data['replyToText'] = replyToText;
    if (sendOpener) data['sendOpener'] = true;
    final r = await callable.call<Map<String, dynamic>>(data);
    return r.data['messageId'] as String?;
  }

  // ── Telegram: индикатор «отвечает [имя]» ─────────────────────────────────

  DateTime? _lastTypingBeat;

  /// Heartbeat «я печатаю» (пишется не чаще раза в 4 сек). Другие менеджеры
  /// видят «отвечает [имя]» — главная защита от двойных ответов.
  Future<void> typingHeartbeat({required String conversationId, required String uid, required String name}) async {
    final now = DateTime.now();
    if (_lastTypingBeat != null && now.difference(_lastTypingBeat!) < const Duration(seconds: 4)) return;
    _lastTypingBeat = now;
    await _db.collection('conversations').doc(conversationId).set({
      'typing': {'uid': uid, 'name': name, 'at': FieldValue.serverTimestamp()},
    }, SetOptions(merge: true));
  }

  /// Снять индикатор (отправил сообщение / закрыл чат / стёр текст).
  /// «Я в этом чате» — мягкий замок от двойных ответов. Пишется при
  /// открытии переписки и обновляется heartbeat'ом раз в 20 секунд;
  /// [since] — момент входа, по нему решается, кто в чате первый.
  Future<void> setViewing(
    String conversationId, {
    required String uid,
    required String name,
    required DateTime since,
  }) =>
      _db.collection('conversations').doc(conversationId).set({
        'viewers': {
          uid: {
            'name': name,
            'at': FieldValue.serverTimestamp(),
            'since': Timestamp.fromDate(since),
          },
        },
      }, SetOptions(merge: true));

  /// Снять отметку «я в чате» (выход из переписки).
  Future<void> clearViewing(String conversationId, String uid) =>
      _db.collection('conversations').doc(conversationId).set({
        'viewers': {uid: FieldValue.delete()},
      }, SetOptions(merge: true));

  Future<void> clearTyping(String conversationId) async {
    _lastTypingBeat = null;
    await _db
        .collection('conversations')
        .doc(conversationId)
        .set({'typing': FieldValue.delete()}, SetOptions(merge: true));
  }

  /// Запрос номера у клиента: текст «напишите ваш номер» + кнопка
  /// «Поделиться номером» (кликается из шапки чата, пока номера нет).
  Future<void> requestPhone(String conversationId) async {
    await _functions
        .httpsCallable('tgRequestPhone')
        .call<Map<String, dynamic>>({'conversationId': conversationId});
  }

  /// Клиент в Telegram видит «печатает…» (sendChatAction, best-effort).
  Future<void> notifyTelegramTyping(String conversationId) async {
    if (!conversationId.startsWith('tg_')) return;
    try {
      await _functions.httpsCallable('tgTyping').call<Map<String, dynamic>>({'conversationId': conversationId});
    } catch (_) {}
  }

  /// Заблокировать/разблокировать контакт (скрытие из списка, без пушей).
  Future<void> setBlocked(String chatId, bool value) => _db
      .collection('conversations')
      .doc(chatId)
      .set({'blocked': value, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  /// Перенести чат в раздел: null — приём (общий поток), 'training' —
  /// обучение, 'supplements' — БАДы. Ручной выбор помечается topicLocked,
  /// чтобы сервер не переразметил чат по ключевым словам следующего
  /// сообщения.
  Future<void> setTopic(String chatId, String? topic) => _db.collection('conversations').doc(chatId).set({
        'topic': topic ?? FieldValue.delete(),
        'topicLocked': true,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  /// Забрать чаты себе или вернуть их общему списку.
  ///
  /// uid — чат виден только этому человеку (у остальных пропадает из списка и
  /// по нему не приходят пуши). null — чат снова общий.
  ///
  /// Пишем пачкой: 10 отдельных запросов дали бы «рваное» исчезновение —
  /// чаты пропадали бы из списка по одному, а при обрыве связи часть осталась
  /// бы забранной, часть нет.
  Future<void> setPrivateOwner(Iterable<String> chatIds, String? uid) async {
    final batch = _db.batch();
    for (final id in chatIds) {
      batch.set(
        _db.collection('conversations').doc(id),
        {
          'privateOwnerUid': uid ?? FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    }
    await batch.commit();
  }

  /// Убрать черновик ИИ из чата — менеджер отправил его, вставил в поле для
  /// правки или просто скрыл. Прямая запись в Firestore, без Cloud Function:
  /// то же самое, что и markRead/clearTyping ниже.
  Future<void> clearAiSuggestion(String chatId) => _db
      .collection('conversations')
      .doc(chatId)
      .set({'aiSuggestion': FieldValue.delete()}, SetOptions(merge: true));

  /// Редактировать своё сообщение (Telegram editMessageText либо Wazzup PATCH).
  Future<void> editText({required String messageId, required String text, String? conversationId}) async {
    if (conversationId != null && conversationId.startsWith('tg_')) {
      await _functions.httpsCallable('tgEditMessage').call<Map<String, dynamic>>(
          {'conversationId': conversationId, 'messageId': messageId, 'text': text});
      return;
    }
    await _functions.httpsCallable('editMessage').call<Map<String, dynamic>>({'messageId': messageId, 'text': text});
  }

  /// Удалить своё сообщение (Telegram deleteMessage либо Wazzup DELETE).
  Future<void> deleteMessage(String messageId, {String? conversationId}) async {
    if (conversationId != null && conversationId.startsWith('tg_')) {
      await _functions.httpsCallable('tgDeleteMessage').call<Map<String, dynamic>>(
          {'conversationId': conversationId, 'messageId': messageId});
      return;
    }
    await _functions.httpsCallable('deleteMessage').call<Map<String, dynamic>>({'messageId': messageId});
  }

  /// Отправка медиа: файл → Firebase Storage → Cloud Function → Telegram
  /// (multipart из функции) либо Wazzup (по contentUri). Токены — на сервере.
  Future<void> sendMedia({
    required String phone,
    required List<int> bytes,
    required String fileName,
    required String contentType,
    required String kind, // image | audio | video | document
    String? conversationId,
    String? name,
    bool sendOpener = false,
  }) async {
    final token = _uuidLike();
    final ext = fileName.contains('.') ? fileName.split('.').last : '';
    final path = 'media/out/${DateTime.now().millisecondsSinceEpoch}_$token${ext.isNotEmpty ? '.$ext' : ''}';
    final ref = FirebaseStorage.instance.ref(path);
    try {
      final task = ref.putData(Uint8List.fromList(bytes), SettableMetadata(contentType: contentType));
      await task.timeout(const Duration(seconds: 45), onTimeout: () {
        throw Exception('Таймаут загрузки в Storage (45с) — данные не идут (проверь правила Storage / App Check)');
      });
    } catch (e) {
      rethrow;
    }
    final mediaUrl = await ref.getDownloadURL();

    await _throttle();
    if (conversationId != null && conversationId.startsWith('tg_')) {
      await _functions.httpsCallable('tgSendMedia').call<Map<String, dynamic>>({
        'conversationId': conversationId,
        'mediaPath': path,
        'mediaUrl': mediaUrl,
        'type': kind,
        'fileName': fileName,
      });
      return;
    }
    final callable = _functions.httpsCallable('sendMedia');
    final data = <String, dynamic>{'phone': phone, 'mediaPath': path, 'mediaUrl': mediaUrl, 'type': kind};
    if (name != null) data['name'] = name;
    if (sendOpener) data['sendOpener'] = true;
    await callable.call<Map<String, dynamic>>(data);
  }

  String _uuidLike() {
    final r = DateTime.now().microsecondsSinceEpoch;
    return r.toRadixString(16);
  }
}
