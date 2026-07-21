import 'package:cloud_firestore/cloud_firestore.dart';

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
    final ref = await _col.add(data);
    return ref.id;
  }

  /// Обновить существующего клиента (updatedAt обновляется автоматически).
  Future<void> update(String id, VipClient client) async {
    final data = client.toCreateMap();
    data['updatedAt'] = FieldValue.serverTimestamp();
    await _col.doc(id).set(data, SetOptions(merge: true));
  }

  /// Поток списка VIP-клиентов (новые сверху).
  Stream<List<VipClient>> watchAll() {
    return _col.orderBy('createdAt', descending: true).snapshots().map(
          (snap) => snap.docs.map(VipClient.fromDoc).toList(),
        );
  }
}
