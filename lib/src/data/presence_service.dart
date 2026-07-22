import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Онлайн-менеджер (Firestore presence/{uid}).
class PresenceUser {
  const PresenceUser(this.uid, this.name);
  final String uid;
  final String name;
}

/// Присутствие менеджеров через Firestore (firebase-режим).
/// Пишем online + lastSeen с heartbeat; онлайн = online && свежий lastSeen.
class FirebasePresenceService {
  FirebasePresenceService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  Timer? _hb;
  String? _uid;
  String? _name;

  CollectionReference<Map<String, dynamic>> get _col => _db.collection('presence');

  void start(String uid, String name) {
    _uid = uid;
    _name = name;
    _write(true);
    _hb?.cancel();
    _hb = Timer.periodic(const Duration(seconds: 45), (_) => _write(true));
  }

  void stop() {
    _hb?.cancel();
    _hb = null;
    if (_uid != null) _write(false);
  }

  Future<void> _write(bool online) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _col.doc(uid).set(
        {'name': _name ?? '', 'online': online, 'lastSeen': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
    } catch (_) {}
  }

  /// Онлайн-менеджеры: online==true и lastSeen не старше 2 минут.
  Stream<List<PresenceUser>> watch() {
    return _col.where('online', isEqualTo: true).snapshots().map((s) {
      final now = DateTime.now();
      final out = <PresenceUser>[];
      for (final d in s.docs) {
        final data = d.data();
        final ls = (data['lastSeen'] as Timestamp?)?.toDate();
        if (ls == null || now.difference(ls).inSeconds > 120) continue;
        out.add(PresenceUser(d.id, (data['name'] ?? '') as String));
      }
      return out;
    });
  }
}
