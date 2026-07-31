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
  DocumentReference<Map<String, dynamic>>? _session;

  CollectionReference<Map<String, dynamic>> get _col => _db.collection('presence');
  CollectionReference<Map<String, dynamic>> get _sessions => _db.collection('workSessions');

  void start(String uid, String name) {
    _uid = uid;
    _name = name;
    _write(true);
    _openSession();
    _hb?.cancel();
    _hb = Timer.periodic(const Duration(seconds: 45), (_) {
      _write(true);
      _touchSession();
    });
  }

  void stop() {
    _hb?.cancel();
    _hb = null;
    if (_uid != null) _write(false);
    _closeSession();
  }

  /// Новая рабочая сессия (для аналитики «когда зашёл/вышел»).
  Future<void> _openSession() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      _session = await _sessions.add({
        'uid': uid,
        'name': _name ?? '',
        'startAt': FieldValue.serverTimestamp(),
        'lastActiveAt': FieldValue.serverTimestamp(),
        'endAt': null,
      });
    } catch (_) {}
  }

  /// Heartbeat сессии: если приложение убьют, конец сессии = lastActiveAt.
  Future<void> _touchSession() async {
    try {
      await _session?.set({'lastActiveAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> _closeSession() async {
    final s = _session;
    _session = null;
    try {
      await s?.set(
        {'endAt': FieldValue.serverTimestamp(), 'lastActiveAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
    } catch (_) {}
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
  ///
  /// Если приложение убили (или телефон уснул), документ остаётся online==true
  /// с протухшим lastSeen. Одного snapshots() мало: без новых событий список
  /// «зависает» и все выглядят в сети. Поэтому пересчитываем ещё и по таймеру.
  Stream<List<PresenceUser>> watch() {
    late final StreamController<List<PresenceUser>> ctrl;
    QuerySnapshot<Map<String, dynamic>>? last;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? sub;
    Timer? tick;

    List<PresenceUser> compute() {
      final now = DateTime.now();
      final out = <PresenceUser>[];
      for (final d in last?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
        final data = d.data();
        final ls = (data['lastSeen'] as Timestamp?)?.toDate();
        if (ls == null || now.difference(ls).inSeconds > 120) continue;
        out.add(PresenceUser(d.id, (data['name'] ?? '') as String));
      }
      return out;
    }

    ctrl = StreamController<List<PresenceUser>>(
      onListen: () {
        sub = _col.where('online', isEqualTo: true).snapshots().listen(
          (s) {
            last = s;
            ctrl.add(compute());
          },
          onError: ctrl.addError,
        );
        tick = Timer.periodic(const Duration(seconds: 30), (_) {
          if (last != null && !ctrl.isClosed) ctrl.add(compute());
        });
      },
      onCancel: () async {
        tick?.cancel();
        await sub?.cancel();
      },
    );
    return ctrl.stream;
  }
}
