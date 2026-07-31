import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/lead.dart';

/// Доступ к лидам в Firestore (коллекция `leads`).
///
/// Номер лида присваивается атомарно через транзакцию над counters/leads —
/// так нумерация сквозная и без коллизий даже при параллельных сохранениях.
class LeadRepository {
  LeadRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _counter => _db.collection('counters').doc('leads');

  /// Предполагаемый следующий номер (для показа в форме до сохранения).
  Future<int> peekNextNumber() async {
    try {
      final snap = await _counter.get();
      return ((snap.data()?['value'] as num?)?.toInt() ?? 0) + 1;
    } catch (e) {
      return 1;
    }
  }

  /// Создать лид, присвоив следующий номер атомарно. Возвращает номер.
  Future<int> create(Lead lead, {required String? createdBy}) async {
    try {
      final assignedNumber = await _db.runTransaction<int>((tx) async {
        final snap = await tx.get(_counter);
        final next = ((snap.data()?['value'] as num?)?.toInt() ?? 0) + 1;
        tx.set(_counter, {'value': next}, SetOptions(merge: true));

        final leadRef = _db.collection('leads').doc();
        final data = lead.toCreateMap()
          ..['leadNumber'] = next
          ..['createdBy'] = createdBy
          ..['createdAt'] = FieldValue.serverTimestamp()
          ..['updatedAt'] = FieldValue.serverTimestamp();
        tx.set(leadRef, data);
        return next;
      });
      return assignedNumber;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
      }
      rethrow;
    }
  }

  /// Обновить лид (номер и служебные поля не трогаем).
  Future<void> update(String id, Lead lead) async {
    final data = lead.toUpdateMap();
    data['updatedAt'] = FieldValue.serverTimestamp();
    await _db.collection('leads').doc(id).set(data, SetOptions(merge: true));
  }

  /// В архив / из архива (мягкое удаление).
  Future<void> archive(String id, bool value) =>
      _db.collection('leads').doc(id).set({'archived': value, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  /// Удалить лид навсегда.
  Future<void> delete(String id) => _db.collection('leads').doc(id).delete();

  /// Поток списка лидов (по номеру, новые сверху).
  Stream<List<Lead>> watchAll() {
    return _db.collection('leads').orderBy('leadNumber', descending: true).snapshots().map(
          (snap) => snap.docs.map(Lead.fromDoc).toList(),
        );
  }
}
