import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

import '../models/vip_client.dart';

/// Доступ к VIP-клиентам в Firestore (коллекция `clients`).
///
/// Служебные поля добавляются здесь автоматически:
/// - createdBy  — uid менеджера (из сессии приложения)
/// - createdAt  — серверный timestamp (только при создании)
/// - updatedAt  — серверный timestamp (при каждом сохранении)
class VipRepository {
  VipRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _col => _db.collection('clients');

  /// Создать VIP-клиента. Возвращает id нового документа.
  Future<String> create(VipClient client, {required String? createdBy}) async {
    final data = client.toCreateMap();
    data['createdBy'] = createdBy;
    data['createdAt'] = FieldValue.serverTimestamp();
    data['updatedAt'] = FieldValue.serverTimestamp();

    if (Firebase.apps.isEmpty) {
    }

    try {
      final ref = await _col.add(data);
      return ref.id;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
      } else if (e.code == 'unavailable') {
      } else if (e.code == 'not-found') {
      }
      rethrow;
    } catch (e) {
      rethrow;
    }
  }

  /// Обновить существующего клиента (updatedAt обновляется автоматически).
  Future<void> update(String id, VipClient client) async {
    final data = client.toUpdateMap();
    data['updatedAt'] = FieldValue.serverTimestamp();
    await _col.doc(id).set(data, SetOptions(merge: true));
  }

  /// Быстрая смена статуса.
  Future<void> setStatus(String id, VipStatus status) =>
      _col.doc(id).set({'status': status.name, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  /// В архив / из архива (мягкое удаление).
  Future<void> archive(String id, bool value) =>
      _col.doc(id).set({'archived': value, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  /// Удалить клиента навсегда.
  Future<void> delete(String id) => _col.doc(id).delete();

  /// Поток списка VIP-клиентов (новые сверху).
  Stream<List<VipClient>> watchAll() {
    return _col.orderBy('createdAt', descending: true).snapshots().map(
          (snap) => snap.docs.map(VipClient.fromDoc).toList(),
        );
  }
}
