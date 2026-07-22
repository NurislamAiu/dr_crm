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
  });
  final String id;
  final String name;
  final String? phone;
  final String? preview;
  final DateTime? lastMessageAt;
  final int unreadCount;

  static FsConversation fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return FsConversation(
      id: doc.id,
      name: (d['name'] ?? doc.id) as String,
      phone: d['phone'] as String?,
      preview: d['lastMessagePreview'] as String?,
      lastMessageAt: (d['lastMessageAt'] as Timestamp?)?.toDate(),
      unreadCount: (d['unreadCount'] as num?)?.toInt() ?? 0,
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
  });
  final String id;
  final String direction; // inbound | outbound
  final String type;
  final String? text;
  final String? contentUri;
  final String? mediaUrl; // durable-ссылка (Storage), fallback contentUri
  final String status;
  final DateTime? createdAt;

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
    );
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
        debugPrint('[FB-SEND] троттлинг: пауза ${wait.inMilliseconds} мс (анти-бан)');
        await Future.delayed(wait);
      }
    }
    _lastSendAt = DateTime.now();
  }

  Stream<List<FsConversation>> watchConversations() {
    debugPrint('[FB] подписка на conversations');
    return _db.collection('conversations').orderBy('lastMessageAt', descending: true).snapshots().map(
      (s) {
        debugPrint('[FB] conversations: ${s.docs.length} шт.');
        return s.docs.map(FsConversation.fromDoc).toList();
      },
    );
  }

  Stream<List<FsMessage>> watchMessages(String conversationId) {
    debugPrint('[FB] подписка на messages conversationId=$conversationId');
    // Последние 100 (desc + limit), затем разворот для показа снизу вверх.
    return _db
        .collection('messages')
        .where('conversationId', isEqualTo: conversationId)
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots()
        .map((s) {
      debugPrint('[FB] messages($conversationId): ${s.docs.length} шт.');
      return s.docs.map(FsMessage.fromDoc).toList().reversed.toList();
    });
  }

  Future<void> markRead(String conversationId) {
    return _db.collection('conversations').doc(conversationId).set({'unreadCount': 0}, SetOptions(merge: true));
  }

  /// Отправка текста через Cloud Function (sendMessage → Wazzup + Firestore).
  Future<void> sendText({required String phone, required String text, String? name}) async {
    debugPrint('[FB-SEND] текст → $phone: "${text.length > 30 ? '${text.substring(0, 30)}…' : text}"');
    await _throttle();
    final callable = _functions.httpsCallable('sendMessage');
    final data = <String, dynamic>{'phone': phone, 'text': text};
    if (name != null) data['name'] = name;
    try {
      final res = await callable.call<Map<String, dynamic>>(data);
      debugPrint('[FB-SEND] ✅ sendMessage ответ: ${res.data}');
    } catch (e) {
      debugPrint('[FB-SEND] ❌ sendMessage ошибка: $e');
      rethrow;
    }
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
    debugPrint('[FB-MEDIA] старт: $kind, ${bytes.length} байт, $contentType → Storage: $path');
    debugPrint('[FB-MEDIA] bucket=${FirebaseStorage.instance.bucket}');
    final ref = FirebaseStorage.instance.ref(path);
    try {
      final task = ref.putData(Uint8List.fromList(bytes), SettableMetadata(contentType: contentType));
      task.snapshotEvents.listen(
        (s) => debugPrint('[FB-MEDIA] прогресс: ${s.bytesTransferred}/${s.totalBytes} state=${s.state}'),
        onError: (e) => debugPrint('[FB-MEDIA] событие-ошибка: $e'),
      );
      await task.timeout(const Duration(seconds: 45), onTimeout: () {
        throw Exception('Таймаут загрузки в Storage (45с) — данные не идут (проверь правила Storage / App Check)');
      });
      debugPrint('[FB-MEDIA] ✅ загружено в Storage');
    } catch (e) {
      debugPrint('[FB-MEDIA] ❌ ошибка загрузки в Storage: $e');
      rethrow;
    }
    final mediaUrl = await ref.getDownloadURL();
    debugPrint('[FB-MEDIA] URL: $mediaUrl');

    await _throttle();
    final callable = _functions.httpsCallable('sendMedia');
    final data = <String, dynamic>{'phone': phone, 'mediaPath': path, 'mediaUrl': mediaUrl, 'type': kind};
    if (name != null) data['name'] = name;
    try {
      final res = await callable.call<Map<String, dynamic>>(data);
      debugPrint('[FB-MEDIA] ✅ sendMedia ответ: ${res.data}');
    } catch (e) {
      debugPrint('[FB-MEDIA] ❌ sendMedia ошибка: $e');
      rethrow;
    }
  }

  String _uuidLike() {
    final r = DateTime.now().microsecondsSinceEpoch;
    return r.toRadixString(16);
  }
}
