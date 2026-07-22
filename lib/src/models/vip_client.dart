import 'package:cloud_firestore/cloud_firestore.dart';

/// Статусы ведения VIP-клиента (Firestore поле `status`).
enum VipStatus {
  awaitingArrival,
  met,
  inHotel,
  inTreatment,
  preparingDeparture,
  departed,
  completed;

  static VipStatus fromId(String? id) =>
      VipStatus.values.firstWhere((s) => s.name == id, orElse: () => VipStatus.awaitingArrival);

  String get label => switch (this) {
        VipStatus.awaitingArrival => 'Ожидает прилёта',
        VipStatus.met => 'Встречен',
        VipStatus.inHotel => 'В отеле',
        VipStatus.inTreatment => 'На лечении',
        VipStatus.preparingDeparture => 'Готовится к вылету',
        VipStatus.departed => 'Улетел',
        VipStatus.completed => 'Завершён',
      };
}

/// VIP-клиент клиники (Firestore коллекция `clients`).
/// Только поля из ТЗ — без файлов/фото (Storage не используется).
class VipClient {
  VipClient({
    this.id,
    this.clientNumber,
    required this.name,
    this.phone,
    this.country,
    this.city,
    this.arrivalDate,
    this.arrivalTime,
    this.arrivalFlight,
    this.hotel,
    this.doctorName,
    this.doctorAppointmentDate,
    this.doctorAppointmentTime,
    this.departureDate,
    this.departureTime,
    this.departureFlight,
    this.driverName,
    this.driverPhone,
    this.status = VipStatus.awaitingArrival,
    this.notes,
    this.archived = false,
  });

  final String? id;
  final bool archived;

  // Личные данные
  final String? clientNumber;
  final String name;
  final String? phone;
  final String? country;
  final String? city;

  // Прибытие
  final DateTime? arrivalDate;
  final String? arrivalTime;
  final String? arrivalFlight;

  // Отель
  final String? hotel;

  // Приём у врача
  final String? doctorName;
  final DateTime? doctorAppointmentDate;
  final String? doctorAppointmentTime;

  // Вылет
  final DateTime? departureDate;
  final String? departureTime;
  final String? departureFlight;

  // Встреча / водитель
  final String? driverName;
  final String? driverPhone;

  // Прочее
  final VipStatus status;
  final String? notes;

  /// Данные для записи в Firestore. Служебные поля (createdBy/createdAt/
  /// updatedAt) добавляет репозиторий — здесь их нет.
  Map<String, dynamic> toCreateMap() {
    final m = <String, dynamic>{
      'clientNumber': clientNumber,
      'name': name,
      'phone': phone,
      'country': country,
      'city': city,
      'arrivalDate': arrivalDate != null ? Timestamp.fromDate(arrivalDate!) : null,
      'arrivalTime': arrivalTime,
      'arrivalFlight': arrivalFlight,
      'hotel': hotel,
      'doctorName': doctorName,
      'doctorAppointmentDate':
          doctorAppointmentDate != null ? Timestamp.fromDate(doctorAppointmentDate!) : null,
      'doctorAppointmentTime': doctorAppointmentTime,
      'departureDate': departureDate != null ? Timestamp.fromDate(departureDate!) : null,
      'departureTime': departureTime,
      'departureFlight': departureFlight,
      'driverName': driverName,
      'driverPhone': driverPhone,
      'status': status.name,
      'notes': notes,
    };
    // Пустые строки не пишем — оставляем null для чистоты документа.
    m.removeWhere((_, v) => v == null || (v is String && v.trim().isEmpty));
    return m;
  }

  /// Карта для обновления: очищенные поля удаляются (FieldValue.delete),
  /// заполненные — перезаписываются. createdBy/createdAt не трогаем.
  Map<String, dynamic> toUpdateMap() {
    final full = <String, dynamic>{
      'clientNumber': clientNumber,
      'name': name,
      'phone': phone,
      'country': country,
      'city': city,
      'arrivalDate': arrivalDate != null ? Timestamp.fromDate(arrivalDate!) : null,
      'arrivalTime': arrivalTime,
      'arrivalFlight': arrivalFlight,
      'hotel': hotel,
      'doctorName': doctorName,
      'doctorAppointmentDate': doctorAppointmentDate != null ? Timestamp.fromDate(doctorAppointmentDate!) : null,
      'doctorAppointmentTime': doctorAppointmentTime,
      'departureDate': departureDate != null ? Timestamp.fromDate(departureDate!) : null,
      'departureTime': departureTime,
      'departureFlight': departureFlight,
      'driverName': driverName,
      'driverPhone': driverPhone,
      'status': status.name,
      'notes': notes,
    };
    return full.map((k, v) {
      final empty = v == null || (v is String && v.trim().isEmpty);
      return MapEntry(k, empty ? FieldValue.delete() : v);
    });
  }

  static VipClient fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    return VipClient(
      id: doc.id,
      clientNumber: d['clientNumber'] as String?,
      name: (d['name'] as String?) ?? '',
      phone: d['phone'] as String?,
      country: d['country'] as String?,
      city: d['city'] as String?,
      arrivalDate: ts(d['arrivalDate']),
      arrivalTime: d['arrivalTime'] as String?,
      arrivalFlight: d['arrivalFlight'] as String?,
      hotel: d['hotel'] as String?,
      doctorName: d['doctorName'] as String?,
      doctorAppointmentDate: ts(d['doctorAppointmentDate']),
      doctorAppointmentTime: d['doctorAppointmentTime'] as String?,
      departureDate: ts(d['departureDate']),
      departureTime: d['departureTime'] as String?,
      departureFlight: d['departureFlight'] as String?,
      driverName: d['driverName'] as String?,
      driverPhone: d['driverPhone'] as String?,
      status: VipStatus.fromId(d['status'] as String?),
      notes: d['notes'] as String?,
      archived: d['archived'] == true,
    );
  }
}
