import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Диалог из Firestore (коллекция conversations, ключ = chatId).
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

  static FsConversation fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return FsConversation(
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
      ..statusError = d['statusError'] as String?;
  }
}

/// Чаты поверх Firestore + отправка через Cloud Function sendMessage.
class FirestoreChatRepository {
  FirestoreChatRepository({FirebaseFirestore? db, FirebaseFunctions? functions})
      : _db = db ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

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
        .map((s) => s.docs.map(FsConversation.fromDoc).toList());
  }

  Stream<List<FsMessage>> watchMessages(String conversationId) {
    // Последние 100 (desc + limit), затем разворот для показа снизу вверх.
    return _db
        .collection('messages')
        .where('conversationId', isEqualTo: conversationId)
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
        .map((s) {
      return s.docs.map(FsMessage.fromDoc).toList().reversed.toList();
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

  /// Отправка текста через Cloud Function (sendMessage → Wazzup + Firestore).
  /// [refMessageId] — ответ (цитата) на сообщение.
  Future<void> sendText({required String phone, required String text, String? name, String? refMessageId, String? replyToText}) async {
    await _throttle();
    final callable = _functions.httpsCallable('sendMessage');
    final data = <String, dynamic>{'phone': phone, 'text': text};
    if (name != null) data['name'] = name;
    if (refMessageId != null) data['refMessageId'] = refMessageId;
    if (replyToText != null) data['replyToText'] = replyToText;
    await callable.call<Map<String, dynamic>>(data);
  }

  /// Заблокировать/разблокировать контакт (скрытие из списка, без пушей).
  Future<void> setBlocked(String chatId, bool value) => _db
      .collection('conversations')
      .doc(chatId)
      .set({'blocked': value, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  /// Редактировать своё сообщение (Wazzup PATCH + Firestore).
  Future<void> editText({required String messageId, required String text}) async {
    await _functions.httpsCallable('editMessage').call<Map<String, dynamic>>({'messageId': messageId, 'text': text});
  }

  /// Удалить своё сообщение (Wazzup DELETE + пометка).
  Future<void> deleteMessage(String messageId) async {
    await _functions.httpsCallable('deleteMessage').call<Map<String, dynamic>>({'messageId': messageId});
  }

  /// Отправка медиа: файл → Firebase Storage → Cloud Function sendMedia → Wazzup.
  Future<void> sendMedia({
    required String phone,
    required List<int> bytes,
    required String fileName,
    required String contentType,
    required String kind, // image | audio | video | document
    String? name,
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
    final callable = _functions.httpsCallable('sendMedia');
    final data = <String, dynamic>{'phone': phone, 'mediaPath': path, 'mediaUrl': mediaUrl, 'type': kind};
    if (name != null) data['name'] = name;
    await callable.call<Map<String, dynamic>>(data);
  }

  String _uuidLike() {
    final r = DateTime.now().microsecondsSinceEpoch;
    return r.toRadixString(16);
  }
}
