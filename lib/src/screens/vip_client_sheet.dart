import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/vip_client.dart';
import '../state/providers.dart';

const _vipRed = Color(0xFFE23744);

/// Bottom sheet создания VIP-клиента (сохранение в Firestore `clients`).
class VipClientSheet extends ConsumerStatefulWidget {
  const VipClientSheet({super.key, this.prefillName, this.prefillPhone});
  final String? prefillName;
  final String? prefillPhone;

  static Future<void> show(BuildContext context, {String? name, String? phone}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => VipClientSheet(prefillName: name, prefillPhone: phone),
    );
  }

  @override
  ConsumerState<VipClientSheet> createState() => _VipClientSheetState();
}

class _VipClientSheetState extends ConsumerState<VipClientSheet> {
  final _formKey = GlobalKey<FormState>();

  final _clientNumber = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _country = TextEditingController();
  final _city = TextEditingController();
  final _arrivalFlight = TextEditingController();
  final _hotel = TextEditingController();
  final _doctorName = TextEditingController();
  final _departureFlight = TextEditingController();
  final _driverName = TextEditingController();
  final _driverPhone = TextEditingController();
  final _notes = TextEditingController();

  DateTime? _arrivalDate;
  TimeOfDay? _arrivalTime;
  DateTime? _doctorDate;
  TimeOfDay? _doctorTime;
  DateTime? _departureDate;
  TimeOfDay? _departureTime;
  VipStatus _status = VipStatus.awaitingArrival;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.prefillName != null) _name.text = widget.prefillName!;
    if (widget.prefillPhone != null) _phone.text = widget.prefillPhone!;
  }

  @override
  void dispose() {
    for (final c in [
      _clientNumber, _name, _phone, _country, _city, _arrivalFlight, _hotel,
      _doctorName, _departureFlight, _driverName, _driverPhone, _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _hhmm(TimeOfDay? t) =>
      t == null ? null : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final client = VipClient(
      clientNumber: _clientNumber.text,
      name: _name.text.trim(),
      phone: _phone.text,
      country: _country.text,
      city: _city.text,
      arrivalDate: _arrivalDate,
      arrivalTime: _hhmm(_arrivalTime),
      arrivalFlight: _arrivalFlight.text,
      hotel: _hotel.text,
      doctorName: _doctorName.text,
      doctorAppointmentDate: _doctorDate,
      doctorAppointmentTime: _hhmm(_doctorTime),
      departureDate: _departureDate,
      departureTime: _hhmm(_departureTime),
      departureFlight: _departureFlight.text,
      driverName: _driverName.text,
      driverPhone: _driverPhone.text,
      status: _status,
      notes: _notes.text,
    );
    try {
      await ref.read(vipRepositoryProvider).create(
            client,
            createdBy: ref.read(appConfigProvider).userId,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('VIP-клиент «${client.name}» сохранён'), backgroundColor: _vipRed),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не сохранено: $e'), backgroundColor: Colors.red.shade700),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.96,
        expand: false,
        builder: (context, scrollCtrl) => Column(
          children: [
            _handle(),
            _header(),
            const Divider(height: 1),
            Expanded(
              child: Form(
                key: _formKey,
                child: ListView(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    _section('Личные данные', Icons.person_outline, [
                      _text(_clientNumber, 'Номер клиента', keyboard: TextInputType.text),
                      _text(_name, 'Имя *', required: true),
                      _text(_phone, 'Телефон', keyboard: TextInputType.phone),
                      _text(_country, 'Страна'),
                      _text(_city, 'Город'),
                    ]),
                    _section('Прибытие', Icons.flight_land, [
                      _dateRow('Дата прилёта', _arrivalDate, (d) => setState(() => _arrivalDate = d)),
                      _timeRow('Время прилёта', _arrivalTime, (t) => setState(() => _arrivalTime = t)),
                      _text(_arrivalFlight, 'Номер рейса'),
                    ]),
                    _section('Отель', Icons.hotel_outlined, [
                      _text(_hotel, 'Название гостиницы'),
                    ]),
                    _section('Приём у врача', Icons.medical_services_outlined, [
                      _text(_doctorName, 'Имя врача'),
                      _dateRow('Дата приёма', _doctorDate, (d) => setState(() => _doctorDate = d)),
                      _timeRow('Время приёма', _doctorTime, (t) => setState(() => _doctorTime = t)),
                    ]),
                    _section('Вылет', Icons.flight_takeoff, [
                      _dateRow('Дата вылета', _departureDate, (d) => setState(() => _departureDate = d)),
                      _timeRow('Время вылета', _departureTime, (t) => setState(() => _departureTime = t)),
                      _text(_departureFlight, 'Обратный рейс'),
                    ]),
                    _section('Встреча / водитель', Icons.directions_car_outlined, [
                      _text(_driverName, 'Кто встречает'),
                      _text(_driverPhone, 'Телефон встречающего', keyboard: TextInputType.phone),
                    ]),
                    _section('Прочее', Icons.info_outline, [
                      _statusField(),
                      const SizedBox(height: 12),
                      _text(_notes, 'Комментарий', maxLines: 3),
                    ]),
                  ],
                ),
              ),
            ),
            _saveBar(),
          ],
        ),
      ),
    );
  }

  Widget _handle() => Container(
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        width: 40,
        height: 4,
        decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)),
      );

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 12),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: _vipRed, borderRadius: BorderRadius.circular(9)),
            alignment: Alignment.center,
            child: const Text('VIP', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Новый VIP-клиент', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        ]),
      );

  Widget _section(String title, IconData icon, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Row(children: [
                Icon(icon, size: 18, color: _vipRed),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
              ]),
            ),
            ...children,
          ],
        ),
      );

  Widget _text(TextEditingController c, String label,
      {bool required = false, TextInputType? keyboard, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: c,
        keyboardType: keyboard,
        maxLines: maxLines,
        textInputAction: maxLines > 1 ? TextInputAction.newline : TextInputAction.next,
        inputFormatters: keyboard == TextInputType.phone
            ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\- ]'))]
            : null,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        validator: required ? (v) => (v == null || v.trim().isEmpty) ? 'Обязательное поле' : null : null,
      ),
    );
  }

  Widget _dateRow(String label, DateTime? value, ValueChanged<DateTime?> onPick) {
    return _pickerTile(
      icon: Icons.calendar_today_outlined,
      label: label,
      valueText: value != null ? DateFormat('dd.MM.yyyy').format(value) : 'не выбрано',
      onTap: () async {
        final now = DateTime.now();
        final d = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          firstDate: DateTime(now.year - 1),
          lastDate: DateTime(now.year + 3),
        );
        if (d != null) onPick(d);
      },
      onClear: value != null ? () => onPick(null) : null,
    );
  }

  Widget _timeRow(String label, TimeOfDay? value, ValueChanged<TimeOfDay?> onPick) {
    return _pickerTile(
      icon: Icons.access_time,
      label: label,
      valueText: value != null ? _hhmm(value)! : 'не выбрано',
      onTap: () async {
        final t = await showTimePicker(context: context, initialTime: value ?? TimeOfDay.now());
        if (t != null) onPick(t);
      },
      onClear: value != null ? () => onPick(null) : null,
    );
  }

  Widget _pickerTile({
    required IconData icon,
    required String label,
    required String valueText,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    final set = valueText != 'не выбрано';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Row(children: [
            Icon(icon, size: 18, color: set ? _vipRed : Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: Text(valueText,
                  style: TextStyle(fontSize: 15, color: set ? null : Colors.grey, fontWeight: set ? FontWeight.w600 : null)),
            ),
            if (onClear != null)
              GestureDetector(onTap: onClear, child: const Icon(Icons.close, size: 16, color: Colors.grey)),
          ]),
        ),
      ),
    );
  }

  Widget _statusField() {
    return DropdownButtonFormField<VipStatus>(
      initialValue: _status,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Статус',
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      items: [
        for (final s in VipStatus.values) DropdownMenuItem(value: s, child: Text(s.label)),
      ],
      onChanged: (s) => setState(() => _status = s ?? _status),
    );
  }

  Widget _saveBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          height: 50,
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _vipRed,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check),
            label: Text(_saving ? 'Сохранение…' : 'Сохранить клиента', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }
}
