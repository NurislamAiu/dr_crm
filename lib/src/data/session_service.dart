import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Активная сессия в системе (sessions/current).
class ActiveSession {
  const ActiveSession({required this.uid, required this.name, required this.sessionId});
  final String uid;
  final String name;
  final String sessionId;
}

/// Одновременно в системе работает только один менеджер.
/// Кто вошёл последним — тот и работает; предыдущего выкидывает
/// (как в WhatsApp Web). Состояние — один документ sessions/current.
class SessionService {
  SessionService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _doc => _db.collection('sessions').doc('current');
  DocumentReference<Map<String, dynamic>> get _cfg => _db.collection('config').doc('access');

  /// Включено ли правило «один менеджер в системе» (по умолчанию — да).
  /// Админа правило не касается: он работает параллельно и никого не выкидывает.
  Stream<bool> watchEnabled() => _cfg.snapshots().map((s) => s.data()?['singleSession'] != false);

  Future<void> setEnabled(bool value) =>
      _cfg.set({'singleSession': value, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  String? _mySessionId;

  /// Мой ли это сеанс (сравнение по случайному id, а не по uid —
  /// чтобы ловить вход того же менеджера с другого телефона).
  bool get hasClaim => _mySessionId != null;
  String? get mySessionId => _mySessionId;

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(20, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Занять систему за собой (при входе / запуске приложения).
  Future<void> claim({required String uid, required String name}) async {
    final id = _randomId();
    _mySessionId = id;
    await _doc.set({
      'uid': uid,
      'name': name,
      'sessionId': id,
      'at': FieldValue.serverTimestamp(),
    });
  }

  /// Освободить систему при выходе (только если сеанс всё ещё мой).
  Future<void> release() async {
    final id = _mySessionId;
    _mySessionId = null;
    if (id == null) return;
    try {
      final snap = await _doc.get();
      if (snap.data()?['sessionId'] == id) {
        await _doc.set({'sessionId': null, 'uid': null, 'name': null, 'at': FieldValue.serverTimestamp()});
      }
    } catch (_) {}
  }

  /// Кто сейчас в системе (null — свободна).
  Stream<ActiveSession?> watch() => _doc.snapshots().map((s) {
        final d = s.data();
        final sid = d?['sessionId'] as String?;
        if (d == null || sid == null || sid.isEmpty) return null;
        return ActiveSession(
          uid: (d['uid'] ?? '') as String,
          name: ((d['name'] ?? '') as String).trim(),
          sessionId: sid,
        );
      });
}
