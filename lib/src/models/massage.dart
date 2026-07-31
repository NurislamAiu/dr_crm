import 'package:cloud_firestore/cloud_firestore.dart';

/// Запись на массаж (Firestore коллекция `massages`). Номер присваивается
/// автоматически (атомарный счётчик counters/massages).
class Massage {
  Massage({
    this.id,
    this.massageNumber,
    required this.name,
    this.phone,
    this.appointmentDate,
    this.appointmentTime,
    this.prepayment,
    this.currency,
    this.archived = false,
    this.createdAt,
    this.createdBy,
  });

  final String? id;
  final int? massageNumber;
  final String name;
  final String? phone;
  final bool archived;
  final DateTime? createdAt;

  /// uid менеджера-создателя (пишется репозиторием, только чтение).
  final String? createdBy;

  /// Приём у врача — день и время.
  final DateTime? appointmentDate;
  final String? appointmentTime;

  /// Сумма предоплаты.
  final num? prepayment;

  /// Валюта предоплаты: 'KZT' (₸) или 'RUB' (₽).
  final String? currency;

  Map<String, dynamic> toCreateMap() {
    final m = <String, dynamic>{
      'name': name,
      'phone': phone,
      'appointmentDate': appointmentDate != null ? Timestamp.fromDate(appointmentDate!) : null,
      'appointmentTime': appointmentTime,
      'prepayment': prepayment,
      'currency': currency,
    };
    m.removeWhere((_, v) => v == null || (v is String && v.trim().isEmpty));
    return m;
  }

  /// Карта для обновления: очищенные поля удаляются, заполненные — пишутся.
  /// massageNumber/createdBy/createdAt не трогаем.
  Map<String, dynamic> toUpdateMap() {
    final full = <String, dynamic>{
      'name': name,
      'phone': phone,
      'appointmentDate': appointmentDate != null ? Timestamp.fromDate(appointmentDate!) : null,
      'appointmentTime': appointmentTime,
      'prepayment': prepayment,
      'currency': currency,
    };
    return full.map((k, v) {
      final empty = v == null || (v is String && v.trim().isEmpty);
      return MapEntry(k, empty ? FieldValue.delete() : v);
    });
  }

  static Massage fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return Massage(
      id: doc.id,
      massageNumber: (d['massageNumber'] as num?)?.toInt(),
      name: (d['name'] as String?) ?? '',
      phone: d['phone'] as String?,
      appointmentDate: d['appointmentDate'] is Timestamp ? (d['appointmentDate'] as Timestamp).toDate() : null,
      appointmentTime: d['appointmentTime'] as String?,
      prepayment: d['prepayment'] as num?,
      currency: d['currency'] as String?,
      archived: d['archived'] == true,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      createdBy: d['createdBy'] as String?,
    );
  }
}
