import 'package:cloud_firestore/cloud_firestore.dart';

/// Строка серверной рассылки.
class BroadcastRow {
  const BroadcastRow({required this.name, required this.phone, required this.date, required this.status, this.variant, this.error});
  final String name;
  final String phone;
  final String date;
  final String status; // pending | sent | failed
  final int? variant;
  final String? error;

  static BroadcastRow fromMap(Map<String, dynamic> m) => BroadcastRow(
        name: (m['name'] ?? '') as String,
        phone: (m['phone'] ?? '') as String,
        date: (m['date'] ?? '') as String,
        status: (m['status'] ?? 'pending') as String,
        variant: (m['variant'] as num?)?.toInt(),
        error: m['error'] as String?,
      );
}

/// Документ рассылки (broadcasts/{id}).
class BroadcastDoc {
  const BroadcastDoc({
    required this.id,
    required this.status,
    required this.rows,
    required this.sent,
    required this.failed,
    required this.total,
    this.createdAt,
    this.lastSentAt,
  });
  final String id;
  final String status; // running | done | stopped | error
  final List<BroadcastRow> rows;
  final int sent;
  final int failed;
  final int total;
  final DateTime? createdAt;
  final DateTime? lastSentAt;

  bool get isRunning => status == 'running';
  int get pending => rows.where((r) => r.status == 'pending').length;

  static BroadcastDoc fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final rows = ((d['rows'] ?? []) as List)
        .whereType<Map<String, dynamic>>()
        .map(BroadcastRow.fromMap)
        .toList();
    return BroadcastDoc(
      id: doc.id,
      status: (d['status'] ?? '') as String,
      rows: rows,
      sent: (d['sent'] as num?)?.toInt() ?? 0,
      failed: (d['failed'] as num?)?.toInt() ?? 0,
      total: (d['total'] as num?)?.toInt() ?? rows.length,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      lastSentAt: (d['lastSentAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Серверная рассылка: приложение только создаёт задание и наблюдает —
/// отправкой (с паузой 20 c) занимается Cloud Function, телефон можно закрыть.
class BroadcastRepository {
  BroadcastRepository({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _col => _db.collection('broadcasts');

  /// Создать задание рассылки. Отправка начнётся в течение минуты.
  Future<String> start({
    required String createdBy,
    required List<({String name, String phone, String date})> rows,
    required List<String> variants,
    required String mode, // rotate | random | single
    required int singleIndex,
  }) async {
    final doc = await _col.add({
      'status': 'running',
      'createdBy': createdBy,
      'mode': mode,
      'singleIndex': singleIndex,
      'variants': variants,
      'delaySec': 20,
      'rows': [
        for (final r in rows) {'name': r.name, 'phone': r.phone, 'date': r.date, 'status': 'pending'},
      ],
      'total': rows.length,
      'sent': 0,
      'failed': 0,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return doc.id;
  }

  /// Остановить активную рассылку (уже отправленное не отзывается).
  Future<void> stop(String id) => _col.doc(id).update({'status': 'stopped', 'updatedAt': FieldValue.serverTimestamp()});

  /// Последняя рассылка (для прогресса и статуса на экране).
  Stream<BroadcastDoc?> watchLatest() {
    return _col.orderBy('createdAt', descending: true).limit(1).snapshots().map(
          (s) => s.docs.isEmpty ? null : BroadcastDoc.fromDoc(s.docs.first),
        );
  }
}
