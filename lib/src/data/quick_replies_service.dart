import 'package:cloud_firestore/cloud_firestore.dart';

/// Быстрый ответ (шаблон): заголовок + основной текст.
/// Firestore коллекция `quickReplies`, общая для всех менеджеров.
class QuickReply {
  const QuickReply(this.id, this.title, this.text, {this.pinned = false});
  final String id;
  final String title;
  final String text;

  /// Закреплён наверху списка — и в настройках, и в выборе шаблона в чате.
  final bool pinned;

  /// Шаблон акции. Акции меняются часто и нужны каждый день, поэтому такие
  /// шаблоны поднимаются наверх сами: достаточно начать название со слова
  /// «Акция», закреплять руками не нужно.
  static bool isPromoTitle(String title) =>
      title.trimLeft().toLowerCase().startsWith('акция');
}

/// Быстрые ответы менеджеров (Firestore). Wazzup их через API не отдаёт,
/// поэтому храним и редактируем у себя.
class QuickRepliesService {
  QuickRepliesService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _col => _db.collection('quickReplies');

  Stream<List<QuickReply>> watch() {
    return _col.orderBy('createdAt').snapshots().map((s) {
      final all = s.docs.map((d) {
        final data = d.data();
        final text = (data['text'] ?? '') as String;
        // title может отсутствовать у старых записей — берём начало текста.
        final title = (data['title'] as String?)?.trim();
        final shown = (title == null || title.isEmpty) ? text : title;
        return QuickReply(
          d.id,
          shown,
          text,
          pinned: data['pinned'] == true || QuickReply.isPromoTitle(shown),
        );
      }).toList();
      // Закреплённые наверх, остальные — в прежнем порядке (по дате
      // создания). Раскладываем по двум спискам, а не sort'ом: List.sort в
      // Dart неустойчив и перемешал бы шаблоны внутри групп.
      return [
        ...all.where((r) => r.pinned),
        ...all.where((r) => !r.pinned),
      ];
    });
  }

  /// Закрепить/открепить шаблон. Шаблоны акций держатся наверху по названию
  /// и без этой отметки (см. [QuickReply.isPromoTitle]).
  Future<void> setPinned(String id, bool pinned) => _col.doc(id).set(
        {'pinned': pinned, 'updatedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );

  Future<void> add({required String title, required String text}) async {
    final tx = text.trim();
    if (tx.isEmpty) return;
    await _col.add({'title': title.trim(), 'text': tx, 'createdAt': FieldValue.serverTimestamp()});
  }

  Future<void> update(String id, {required String title, required String text}) =>
      _col.doc(id).set({'title': title.trim(), 'text': text.trim(), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  Future<void> delete(String id) => _col.doc(id).delete();
}
