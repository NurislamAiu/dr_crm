import 'package:cloud_firestore/cloud_firestore.dart';

/// Быстрый ответ (шаблон). Firestore коллекция `quickReplies`, общая для всех.
class QuickReply {
  const QuickReply(this.id, this.text);
  final String id;
  final String text;
}

/// Быстрые ответы менеджеров (Firestore). Wazzup их через API не отдаёт,
/// поэтому храним и редактируем у себя.
class QuickRepliesService {
  QuickRepliesService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _col => _db.collection('quickReplies');

  Stream<List<QuickReply>> watch() {
    return _col.orderBy('createdAt').snapshots().map(
          (s) => s.docs.map((d) => QuickReply(d.id, (d.data()['text'] ?? '') as String)).toList(),
        );
  }

  Future<void> add(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _col.add({'text': t, 'createdAt': FieldValue.serverTimestamp()});
  }

  Future<void> update(String id, String text) => _col.doc(id).set({'text': text.trim()}, SetOptions(merge: true));

  Future<void> delete(String id) => _col.doc(id).delete();
}
