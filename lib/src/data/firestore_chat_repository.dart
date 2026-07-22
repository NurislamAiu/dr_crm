import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

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
    required this.status,
    required this.createdAt,
  });
  final String id;
  final String direction; // inbound | outbound
  final String type;
  final String? text;
  final String? contentUri;
  final String status;
  final DateTime? createdAt;

  bool get isOutbound => direction == 'outbound';

  static FsMessage fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return FsMessage(
      id: doc.id,
      direction: (d['direction'] ?? 'inbound') as String,
      type: (d['type'] ?? 'text') as String,
      text: d['text'] as String?,
      contentUri: d['contentUri'] as String?,
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

  Stream<List<FsConversation>> watchConversations() {
    return _db.collection('conversations').orderBy('lastMessageAt', descending: true).snapshots().map(
          (s) => s.docs.map(FsConversation.fromDoc).toList(),
        );
  }

  Stream<List<FsMessage>> watchMessages(String conversationId) {
    return _db
        .collection('messages')
        .where('conversationId', isEqualTo: conversationId)
        .orderBy('createdAt')
        .snapshots()
        .map((s) => s.docs.map(FsMessage.fromDoc).toList());
  }

  Future<void> markRead(String conversationId) {
    return _db.collection('conversations').doc(conversationId).set({'unreadCount': 0}, SetOptions(merge: true));
  }

  /// Отправка текста через Cloud Function (sendMessage → Wazzup + Firestore).
  Future<void> sendText({required String phone, required String text, String? name}) async {
    final callable = _functions.httpsCallable('sendMessage');
    final data = <String, dynamic>{'phone': phone, 'text': text};
    if (name != null) data['name'] = name;
    await callable.call<Map<String, dynamic>>(data);
  }
}
