import 'package:cloud_firestore/cloud_firestore.dart';

/// Быстрый ответ (шаблон): заголовок + основной текст.
/// Firestore коллекция `quickReplies`, общая для всех менеджеров.
class QuickReply {
  const QuickReply(this.id, this.title, this.text);
  final String id;
  final String title;
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
          (s) => s.docs.map((d) {
            final data = d.data();
            final text = (data['text'] ?? '') as String;
            // title может отсутствовать у старых записей — берём начало текста.
            final title = (data['title'] as String?)?.trim();
            return QuickReply(d.id, (title == null || title.isEmpty) ? text : title, text);
          }).toList(),
        );
  }

  Future<void> add({required String title, required String text}) async {
    final tx = text.trim();
    if (tx.isEmpty) return;
    await _col.add({'title': title.trim(), 'text': tx, 'createdAt': FieldValue.serverTimestamp()});
  }

  Future<void> update(String id, {required String title, required String text}) =>
      _col.doc(id).set({'title': title.trim(), 'text': text.trim(), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  Future<void> delete(String id) => _col.doc(id).delete();
}
