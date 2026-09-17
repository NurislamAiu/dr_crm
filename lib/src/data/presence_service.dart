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
  bool _hidden = false;
  DocumentReference<Map<String, dynamic>>? _session;

  CollectionReference<Map<String, dynamic>> get _col => _db.collection('presence');
  CollectionReference<Map<String, dynamic>> get _sessions => _db.collection('workSessions');

  /// hidden — «невидимка»: присутствие не публикуется, другие менеджеры не
  /// видят этот аккаунт в списке «в сети». Рабочие сессии при этом пишутся
  /// как обычно — это внутренняя аналитика «когда зашёл/вышел», а не
  /// публичный статус.
  void start(String uid, String name, {bool hidden = false}) {
    // Повторный start того же менеджера — только отметка «онлайн», БЕЗ
    // пересоздания таймера и без новой workSession: системный resumed может
    // приходить сериями (Samsung), иначе плодятся тысячи пустых сессий.
    if (_uid == uid && _hb != null) {
      if (!hidden) _write(true);
      return;
    }
    _uid = uid;
    _name = name;
    _hidden = hidden;
    // У невидимки гасим возможный «залипший» онлайн от прошлого входа: без
    // этого документ с online:true прожил бы ещё до двух минут (столько
    // держится свежесть lastSeen в watch), и нас всё равно увидели бы в сети.
    _write(!hidden);
    _openSession();
    _hb?.cancel();
    _hb = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!_hidden) _write(true);
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
            if (ctrl.isClosed) return;
            last = s;
            ctrl.add(compute());
          },
          onError: (Object e, StackTrace st) {
            if (!ctrl.isClosed) ctrl.addError(e, st);
          },
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
