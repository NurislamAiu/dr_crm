import 'package:flutter/foundation.dart';
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

    debugPrint('[VIP] ── создание клиента ──────────────');
    debugPrint('[VIP] Firebase apps: ${Firebase.apps.length} ${Firebase.apps.map((a) => a.name).toList()}');
    if (Firebase.apps.isEmpty) {
      debugPrint('[VIP] ❌ Firebase НЕ инициализирован. Запустите `flutterfire configure` и пересоберите.');
    }
    debugPrint('[VIP] project: ${Firebase.apps.isNotEmpty ? Firebase.app().options.projectId : "—"}');
    debugPrint('[VIP] createdBy(uid): $createdBy');
    debugPrint('[VIP] поля: ${data.keys.toList()}');

    try {
      final ref = await _col.add(data);
      debugPrint('[VIP] ✅ сохранено: clients/${ref.id}');
      return ref.id;
    } on FirebaseException catch (e, st) {
      debugPrint('[VIP] ❌ FirebaseException plugin=${e.plugin} code=${e.code}');
      debugPrint('[VIP]    message: ${e.message}');
      if (e.code == 'permission-denied') {
        debugPrint('[VIP]    → правила Firestore запрещают запись. Включите test-режим '
            'или разрешите write в firestore.rules.');
      } else if (e.code == 'unavailable') {
        debugPrint('[VIP]    → нет сети / Firestore недоступен.');
      } else if (e.code == 'not-found') {
        debugPrint('[VIP]    → база Firestore не создана в консоли (Build → Firestore Database → Create).');
      }
      debugPrint('$st');
      rethrow;
    } catch (e, st) {
      debugPrint('[VIP] ❌ ошибка: $e');
      debugPrint('$st');
      rethrow;
    }
  }

  /// Обновить существующего клиента (updatedAt обновляется автоматически).
  Future<void> update(String id, VipClient client) async {
    final data = client.toUpdateMap();
    data['updatedAt'] = FieldValue.serverTimestamp();
    await _col.doc(id).set(data, SetOptions(merge: true));
  }

  /// Удалить клиента.
  Future<void> delete(String id) => _col.doc(id).delete();

  /// Поток списка VIP-клиентов (новые сверху).
  Stream<List<VipClient>> watchAll() {
    return _col.orderBy('createdAt', descending: true).snapshots().map(
          (snap) => snap.docs.map(VipClient.fromDoc).toList(),
        );
  }
}
