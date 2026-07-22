import 'package:cloud_firestore/cloud_firestore.dart';

/// Настройки автоответчика (Firestore config/autoReply).
class AutoReplyConfig {
  AutoReplyConfig({
    this.enabled = false,
    this.text = '',
    this.outsideHoursOnly = true,
    this.workStart = 9,
    this.workEnd = 20,
    this.tzOffset = 5,
    this.cooldownMin = 360,
    this.missedCallEnabled = false,
    this.missedCallText = '',
  });
  bool enabled;
  String text;
  bool outsideHoursOnly;
  int workStart;
  int workEnd;
  int tzOffset;
  int cooldownMin;
  bool missedCallEnabled;
  String missedCallText;

  Map<String, dynamic> toMap() => {
        'enabled': enabled,
        'text': text.trim(),
        'outsideHoursOnly': outsideHoursOnly,
        'workStart': workStart,
        'workEnd': workEnd,
        'tzOffset': tzOffset,
        'cooldownMin': cooldownMin,
        'missedCallEnabled': missedCallEnabled,
        'missedCallText': missedCallText.trim(),
      };

  static AutoReplyConfig fromMap(Map<String, dynamic>? d) {
    d ??= {};
    return AutoReplyConfig(
      enabled: d['enabled'] == true,
      text: (d['text'] ?? '') as String,
      outsideHoursOnly: d['outsideHoursOnly'] != false,
      workStart: (d['workStart'] as num?)?.toInt() ?? 9,
      workEnd: (d['workEnd'] as num?)?.toInt() ?? 20,
      tzOffset: (d['tzOffset'] as num?)?.toInt() ?? 5,
      cooldownMin: (d['cooldownMin'] as num?)?.toInt() ?? 360,
      missedCallEnabled: d['missedCallEnabled'] == true,
      missedCallText: (d['missedCallText'] ?? '') as String,
    );
  }
}

class AutoReplyService {
  AutoReplyService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _doc => _db.collection('config').doc('autoReply');

  Future<AutoReplyConfig> load() async {
    final snap = await _doc.get();
    return AutoReplyConfig.fromMap(snap.data());
  }

  Future<void> save(AutoReplyConfig cfg) => _doc.set(cfg.toMap(), SetOptions(merge: true));
}
