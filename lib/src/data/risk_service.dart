import 'package:cloud_firestore/cloud_firestore.dart';

/// Событие контроля: подозрительное сообщение или рассылка менеджера.
/// Пишется только сервером (Cloud Functions), читает только админ.
class RiskEvent {
  RiskEvent({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.phone,
    required this.text,
    required this.kinds,
    required this.severity,
    required this.score,
    required this.createdAt,
    this.count,
  });

  final String id;
  final String authorId;
  final String authorName;
  final String? phone;
  final String text;

  /// Что именно сработало: cold | mass | burst | night | card | phone | link |
  /// deleted | blast.
  final List<String> kinds;

  /// high | medium | low.
  final String severity;
  final int score;
  final DateTime? createdAt;

  /// Для рассылки — сколько получателей.
  final int? count;

  bool get isHigh => severity == 'high';

  /// Главный признак (по нему иконка и заголовок карточки).
  String get mainKind {
    for (final k in const ['card', 'mass', 'blast', 'phone', 'burst', 'cold', 'deleted', 'link', 'night']) {
      if (kinds.contains(k)) return k;
    }
    return kinds.isEmpty ? 'cold' : kinds.first;
  }

  static RiskEvent fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return RiskEvent(
      id: doc.id,
      authorId: (d['authorId'] ?? '') as String,
      authorName: ((d['authorName'] ?? '') as String).trim(),
      phone: d['phone'] as String?,
      text: (d['text'] ?? '') as String,
      kinds: ((d['kinds'] ?? const []) as List).map((e) => '$e').toList(),
      severity: (d['severity'] ?? 'low') as String,
      score: (d['score'] as num?)?.toInt() ?? 1,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      count: (d['count'] as num?)?.toInt(),
    );
  }
}

/// Чтение журнала подозрительной активности.
class RiskService {
  RiskService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> get _cfg => _db.collection('config').doc('risk');

  /// Свои номера: если такой номер встретился в тексте — это не нарушение
  /// (правило «чужой номер в сообщении» их пропускает).
  Stream<List<String>> watchAllowedPhones() => _cfg.snapshots().map((s) {
        final list = (s.data()?['allowedPhones'] ?? const []) as List;
        return list.map((e) => '$e').where((e) => e.trim().isNotEmpty).toList();
      });

  Future<void> setAllowedPhones(List<String> phones) =>
      _cfg.set({'allowedPhones': phones}, SetOptions(merge: true));

  /// События за период; [uid] — только по одному менеджеру.
  /// limit(300): журнал растёт, читать его целиком незачем.
  Stream<List<RiskEvent>> watch({required DateTime since, String? uid}) {
    Query<Map<String, dynamic>> q =
        _db.collection('riskEvents').where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since));
    if (uid != null) q = q.where('authorId', isEqualTo: uid);
    return q
        .orderBy('createdAt', descending: true)
        .limit(300)
        .snapshots()
        .map((s) => s.docs.map(RiskEvent.fromDoc).toList());
  }
}
