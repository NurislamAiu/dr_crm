import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/massage.dart';

/// Доступ к записям на массаж в Firestore (коллекция `massages`).
///
/// Номер присваивается атомарно через транзакцию над counters/massages —
/// так нумерация сквозная и без коллизий даже при параллельных сохранениях.
class MassageRepository {
  MassageRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _counter => _db.collection('counters').doc('massages');

  /// Предполагаемый следующий номер (для показа в форме до сохранения).
  Future<int> peekNextNumber() async {
    try {
      final snap = await _counter.get();
      return ((snap.data()?['value'] as num?)?.toInt() ?? 0) + 1;
    } catch (e) {
      return 1;
    }
  }

  /// Создать запись, присвоив следующий номер атомарно. Возвращает номер.
  Future<int> create(Massage lead, {required String? createdBy}) async {
    try {
      final assignedNumber = await _db.runTransaction<int>((tx) async {
        final snap = await tx.get(_counter);
        final next = ((snap.data()?['value'] as num?)?.toInt() ?? 0) + 1;
        tx.set(_counter, {'value': next}, SetOptions(merge: true));

        final leadRef = _db.collection('massages').doc();
        final data = lead.toCreateMap()
          ..['massageNumber'] = next
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

  /// Обновить запись (номер и служебные поля не трогаем).
  Future<void> update(String id, Massage lead) async {
    final data = lead.toUpdateMap();
    data['updatedAt'] = FieldValue.serverTimestamp();
    await _db.collection('massages').doc(id).set(data, SetOptions(merge: true));
  }

  /// В архив / из архива (мягкое удаление).
  Future<void> archive(String id, bool value) =>
      _db.collection('massages').doc(id).set({'archived': value, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  /// Удалить запись навсегда.
  Future<void> delete(String id) => _db.collection('massages').doc(id).delete();

  /// Поток списка записей (по номеру, новые сверху).
  Stream<List<Massage>> watchAll() {
    return _db.collection('massages').orderBy('massageNumber', descending: true).snapshots().map(
          (snap) => snap.docs.map(Massage.fromDoc).toList(),
        );
  }
}
