import 'package:cloud_firestore/cloud_firestore.dart';

/// Лид (Firestore коллекция `leads`). Номер присваивается автоматически
/// (атомарный счётчик counters/leads).
class Lead {
  Lead({
    this.id,
    this.leadNumber,
    required this.name,
    this.phone,
    this.appointmentDate,
    this.appointmentTime,
    this.prepayment,
  });

  final String? id;
  final int? leadNumber;
  final String name;
  final String? phone;

  /// Приём у врача — день и время.
  final DateTime? appointmentDate;
  final String? appointmentTime;

  /// Сумма предоплаты.
  final num? prepayment;

  Map<String, dynamic> toCreateMap() {
    final m = <String, dynamic>{
      'name': name,
      'phone': phone,
      'appointmentDate': appointmentDate != null ? Timestamp.fromDate(appointmentDate!) : null,
      'appointmentTime': appointmentTime,
      'prepayment': prepayment,
    };
    m.removeWhere((_, v) => v == null || (v is String && v.trim().isEmpty));
    return m;
  }

  static Lead fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return Lead(
      id: doc.id,
      leadNumber: (d['leadNumber'] as num?)?.toInt(),
      name: (d['name'] as String?) ?? '',
      phone: d['phone'] as String?,
      appointmentDate: d['appointmentDate'] is Timestamp ? (d['appointmentDate'] as Timestamp).toDate() : null,
      appointmentTime: d['appointmentTime'] as String?,
      prepayment: d['prepayment'] as num?,
    );
  }
}
