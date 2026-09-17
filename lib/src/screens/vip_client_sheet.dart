import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../design/design.dart';
import '../models/vip_client.dart';
import '../state/providers.dart';
import 'soft_ui.dart';

const _vipRed = Color(0xFFE23744);
const _vipRedDark = Color(0xFFC42232);

/// Bottom sheet создания VIP-клиента (сохранение в Firestore `clients`).
class VipClientSheet extends ConsumerStatefulWidget {
  const VipClientSheet({super.key, this.prefillName, this.prefillPhone, this.existing});
  final String? prefillName;
  final String? prefillPhone;

  /// Если задан — режим редактирования существующего клиента.
  final VipClient? existing;

  static Future<void> show(BuildContext context, {String? name, String? phone, VipClient? existing}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VipClientSheet(prefillName: name, prefillPhone: phone, existing: existing),
    );
  }

  @override
  ConsumerState<VipClientSheet> createState() => _VipClientSheetState();
}

class _VipClientSheetState extends ConsumerState<VipClientSheet> {
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _country = TextEditingController();
  final _city = TextEditingController();
  final _hotel = TextEditingController();
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

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      // Скрытые в форме поля (clientNumber/arrivalFlight/doctorName/departureFlight)
      // не редактируются, но сохраняются как есть — см. _save.
      _name.text = ex.name;
      _phone.text = ex.phone ?? '';
      _country.text = ex.country ?? '';
      _city.text = ex.city ?? '';
      _hotel.text = ex.hotel ?? '';
      _driverName.text = ex.driverName ?? '';
      _driverPhone.text = ex.driverPhone ?? '';
      _notes.text = ex.notes ?? '';
      _arrivalDate = ex.arrivalDate;
      _arrivalTime = _parseTod(ex.arrivalTime);
      _doctorDate = ex.doctorAppointmentDate;
      _doctorTime = _parseTod(ex.doctorAppointmentTime);
      _departureDate = ex.departureDate;
      _departureTime = _parseTod(ex.departureTime);
      _status = ex.status;
    } else {
      if (widget.prefillName != null) _name.text = widget.prefillName!;
      if (widget.prefillPhone != null) _phone.text = widget.prefillPhone!;
    }
  }

  TimeOfDay? _parseTod(String? s) {
    if (s == null) return null;
    final p = s.split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _country, _city, _hotel, _driverName, _driverPhone, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _hhmm(TimeOfDay? t) =>
      t == null ? null : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      HapticFeedback.lightImpact();
      return;
    }
    setState(() => _saving = true);
    final ex = widget.existing;
    final client = VipClient(
      // Скрытые поля переносим без изменений при редактировании.
      clientNumber: ex?.clientNumber,
      arrivalFlight: ex?.arrivalFlight,
      doctorName: ex?.doctorName,
      departureFlight: ex?.departureFlight,
      name: _name.text.trim(),
      phone: _phone.text,
      country: _country.text,
      city: _city.text,
      arrivalDate: _arrivalDate,
      arrivalTime: _hhmm(_arrivalTime),
      hotel: _hotel.text,
      doctorAppointmentDate: _doctorDate,
      doctorAppointmentTime: _hhmm(_doctorTime),
      departureDate: _departureDate,
      departureTime: _hhmm(_departureTime),
      driverName: _driverName.text,
      driverPhone: _driverPhone.text,
      status: _status,
      notes: _notes.text,
    );
    try {
      final repo = ref.read(vipRepositoryProvider);
      if (_editing) {
        await repo.update(ex!.id!, client);
      } else {
        await repo.create(client, createdBy: ref.read(appConfigProvider).userId);
      }
      if (!mounted) return;
      Haptics.success();
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(_editing ? 'Изменения сохранены' : 'VIP-клиент «${client.name}» сохранён')),
          ]),
          backgroundColor: _vipRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Haptics.error();
      setState(() => _saving = false);
      final msg = e is FirebaseException
          ? 'Firestore: ${e.code}${e.message != null ? ' — ${e.message}' : ''}'
          : 'Не сохранено: $e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = dark ? const Color(0xFF12191E) : const Color(0xFFF2F5F7);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.93,
        minChildSize: 0.55,
        maxChildSize: 0.96,
        expand: false,
        builder: (context, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: sheetBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: Column(
            children: [
              _grabber(dark),
              _header(dark),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: ListView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                    children: [
                      _card(dark, 'Личные данные', Icons.person_rounded, [
                        _field(dark, _name, 'Имя', icon: Icons.badge_outlined, required: true),
                        _field(dark, _phone, 'Телефон', icon: Icons.phone_outlined, keyboard: TextInputType.phone),
                        Row(children: [
                          Expanded(child: _field(dark, _country, 'Страна', icon: Icons.public)),
                          const SizedBox(width: 10),
                          Expanded(child: _field(dark, _city, 'Город', icon: Icons.location_city_outlined)),
                        ]),
                      ]),
                      _card(dark, 'Прибытие', Icons.flight_land_rounded, [
                        Row(children: [
                          Expanded(child: _dateTile(dark, 'Дата прилёта', _arrivalDate, (d) => setState(() => _arrivalDate = d))),
                          const SizedBox(width: 10),
                          Expanded(child: _timeTile(dark, 'Время', _arrivalTime, (t) => setState(() => _arrivalTime = t))),
                        ]),
                      ]),
                      _card(dark, 'Отель', Icons.hotel_rounded, [
                        _field(dark, _hotel, 'Название гостиницы', icon: Icons.apartment_rounded),
                      ]),
                      _card(dark, 'Приём у врача', Icons.medical_services_rounded, [
                        Row(children: [
                          Expanded(child: _dateTile(dark, 'Дата приёма', _doctorDate, (d) => setState(() => _doctorDate = d))),
                          const SizedBox(width: 10),
                          Expanded(child: _timeTile(dark, 'Время', _doctorTime, (t) => setState(() => _doctorTime = t))),
                        ]),
                      ]),
                      _card(dark, 'Вылет', Icons.flight_takeoff_rounded, [
                        Row(children: [
                          Expanded(child: _dateTile(dark, 'Дата вылета', _departureDate, (d) => setState(() => _departureDate = d))),
                          const SizedBox(width: 10),
                          Expanded(child: _timeTile(dark, 'Время', _departureTime, (t) => setState(() => _departureTime = t))),
                        ]),
                      ]),
                      _card(dark, 'Встреча / водитель', Icons.directions_car_rounded, [
                        _field(dark, _driverName, 'Кто встречает', icon: Icons.person_pin_circle_outlined),
                        _field(dark, _driverPhone, 'Телефон встречающего', icon: Icons.phone_outlined, keyboard: TextInputType.phone),
                      ]),
                      _card(dark, 'Статус', Icons.flag_rounded, [
                        _statusChips(dark),
                      ]),
                      _card(dark, 'Комментарий', Icons.sticky_note_2_rounded, [
                        _field(dark, _notes, 'Заметка по клиенту', maxLines: 3),
                      ]),
                    ],
                  ),
                ),
              ),
              _saveBar(dark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _grabber(bool dark) => Container(
        margin: const EdgeInsets.only(top: 10, bottom: 4),
        width: 42,
        height: 5,
        decoration: BoxDecoration(
          color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(3),
        ),
      );

  Widget _header(bool dark) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 10, 12),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [_vipRed, _vipRedDark]),
              borderRadius: BorderRadius.circular(13),
              boxShadow: [BoxShadow(color: _vipRed.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            alignment: Alignment.center,
            child: const Text('VIP', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.5)),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_editing ? 'Редактирование' : 'Новый VIP-клиент',
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                Text(_editing ? 'Измените данные по визиту' : 'Заполните данные по визиту',
                    style: TextStyle(fontSize: 12.5, color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.5))),
              ],
            ),
          ),
          IconButton(
            style: IconButton.styleFrom(backgroundColor: (dark ? Colors.white : Colors.black).withValues(alpha: 0.05)),
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ]),
      );

  Widget _card(bool dark, String title, IconData icon, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1B242B) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: dark ? Border.all(color: Colors.white.withValues(alpha: 0.05)) : null,
        boxShadow: dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12, left: 2),
            child: Row(children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(color: _vipRed.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, size: 16, color: _vipRed),
              ),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, letterSpacing: 0.1)),
            ]),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _field(bool dark, TextEditingController c, String label,
      {IconData? icon, bool required = false, TextInputType? keyboard, int maxLines = 1}) {
    final fill = dark ? const Color(0xFF232E36) : const Color(0xFFF4F6F8);
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
        style: const TextStyle(fontSize: 15.5),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: icon != null ? Icon(icon, size: 19) : null,
          filled: true,
          fillColor: fill,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: _vipRed, width: 1.5)),
        ),
        validator: required ? (v) => (v == null || v.trim().isEmpty) ? 'Укажите имя' : null : null,
      ),
    );
  }

  Widget _dateTile(bool dark, String label, DateTime? value, ValueChanged<DateTime?> onPick) {
    return _pickTile(
      dark,
      icon: Icons.calendar_month_rounded,
      label: label,
      value: value != null ? DateFormat('dd.MM.yyyy').format(value) : null,
      onTap: () async {
        // Простой календарь-сетка вместо системного диалога.
        final res = await showSoftDatePicker(context, selected: value, accent: _vipRedDark);
        if (res is DateTime) onPick(res);
        if (res == clearDateSentinel) onPick(null);
      },
      onClear: value != null ? () => onPick(null) : null,
    );
  }

  Widget _timeTile(bool dark, String label, TimeOfDay? value, ValueChanged<TimeOfDay?> onPick) {
    return _pickTile(
      dark,
      icon: Icons.schedule_rounded,
      label: label,
      value: value != null ? _hhmm(value) : null,
      onTap: () async {
        final t = await showTimePicker(
          context: context,
          initialTime: value ?? TimeOfDay.now(),
          builder: (ctx, child) => Theme(
            data: Theme.of(ctx).copyWith(colorScheme: Theme.of(ctx).colorScheme.copyWith(primary: _vipRed)),
            child: MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
          ),
        );
        if (t != null) onPick(t);
      },
      onClear: value != null ? () => onPick(null) : null,
    );
  }

  Widget _pickTile(bool dark, {required IconData icon, required String label, String? value, required VoidCallback onTap, VoidCallback? onClear}) {
    final fill = dark ? const Color(0xFF232E36) : const Color(0xFFF4F6F8);
    final set = value != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(13),
          border: set ? Border.all(color: _vipRed.withValues(alpha: 0.4)) : null,
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: set ? _vipRed : Colors.grey),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(fontSize: 10.5, color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.45))),
                const SizedBox(height: 1),
                Text(value ?? 'выбрать',
                    style: TextStyle(fontSize: 14.5, fontWeight: set ? FontWeight.w700 : FontWeight.w400, color: set ? null : Colors.grey)),
              ],
            ),
          ),
          if (onClear != null)
            GestureDetector(onTap: onClear, child: Icon(Icons.close_rounded, size: 15, color: Colors.grey.shade500)),
        ]),
      ),
    );
  }

  Widget _statusChips(bool dark) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in VipStatus.values)
          GestureDetector(
            onTap: () => setState(() => _status = s),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: BoxDecoration(
                color: _status == s ? _vipRed : (dark ? const Color(0xFF232E36) : const Color(0xFFF4F6F8)),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                s.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: _status == s ? FontWeight.w700 : FontWeight.w500,
                  color: _status == s ? Colors.white : (dark ? Colors.white70 : Colors.black87),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _saveBar(bool dark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF12191E) : const Color(0xFFF2F5F7),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.3 : 0.06), blurRadius: 12, offset: const Offset(0, -3))],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _vipRed,
              disabledBackgroundColor: _vipRed.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              elevation: 0,
            ),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.check_rounded, size: 21),
                    const SizedBox(width: 8),
                    Text(_editing ? 'Сохранить изменения' : 'Сохранить клиента', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ]),
          ),
        ),
      ),
    );
  }
}
