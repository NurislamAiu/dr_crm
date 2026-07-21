import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/lead.dart';
import '../state/providers.dart';

const _teal = Color(0xFF13B0A0);
const _tealDark = Color(0xFF0E8F82);

/// Bottom sheet создания лида (сохранение в Firestore `leads` с автономером).
class LeadSheet extends ConsumerStatefulWidget {
  const LeadSheet({super.key, this.prefillName, this.prefillPhone});
  final String? prefillName;
  final String? prefillPhone;

  static Future<void> show(BuildContext context, {String? name, String? phone}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LeadSheet(prefillName: name, prefillPhone: phone),
    );
  }

  @override
  ConsumerState<LeadSheet> createState() => _LeadSheetState();
}

class _LeadSheetState extends ConsumerState<LeadSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _prepay = TextEditingController();

  DateTime? _apptDate;
  TimeOfDay? _apptTime;
  int? _nextNumber;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.prefillName != null) _name.text = widget.prefillName!;
    if (widget.prefillPhone != null) _phone.text = widget.prefillPhone!;
    _name.addListener(() => setState(() {}));
    _phone.addListener(() => setState(() {}));
    ref.read(leadRepositoryProvider).peekNextNumber().then((n) {
      if (mounted) setState(() => _nextNumber = n);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _prepay.dispose();
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
    final lead = Lead(
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      appointmentDate: _apptDate,
      appointmentTime: _hhmm(_apptTime),
      prepayment: _prepay.text.trim().isEmpty ? null : num.tryParse(_prepay.text.replaceAll(',', '.').trim()),
    );
    try {
      final number = await ref.read(leadRepositoryProvider).create(lead, createdBy: ref.read(appConfigProvider).userId);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Лид №$number сохранён'),
          backgroundColor: _teal,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final msg = e is FirebaseException ? 'Firestore: ${e.code}' : 'Не сохранено: $e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700, behavior: SnackBarBehavior.floating),
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
        initialChildSize: 0.82,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollCtrl) => Container(
          decoration: BoxDecoration(color: sheetBg, borderRadius: const BorderRadius.vertical(top: Radius.circular(26))),
          child: Column(
            children: [
              _grabber(dark),
              _header(dark),
              _previewBar(dark),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: ListView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                    children: [
                      _card(dark, 'Приём у врача', Icons.medical_services_rounded, [
                        Row(children: [
                          Expanded(child: _dateTile(dark, 'День', _apptDate, (d) => setState(() => _apptDate = d))),
                          const SizedBox(width: 10),
                          Expanded(child: _timeTile(dark, 'Время', _apptTime, (t) => setState(() => _apptTime = t))),
                        ]),
                      ]),
                      _card(dark, 'Клиент', Icons.person_rounded, [
                        _field(dark, _name, 'Имя', icon: Icons.badge_outlined, required: true),
                        _field(dark, _phone, 'Номер', icon: Icons.phone_outlined, keyboard: TextInputType.phone),
                      ]),
                      _card(dark, 'Предоплата', Icons.payments_rounded, [
                        _field(dark, _prepay, 'Сумма предоплаты', icon: Icons.attach_money_rounded,
                            keyboard: const TextInputType.numberWithOptions(decimal: true), digitsOnly: true),
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
        decoration: BoxDecoration(color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.18), borderRadius: BorderRadius.circular(3)),
      );

  Widget _header(bool dark) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 10, 10),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [_teal, _tealDark]),
              borderRadius: BorderRadius.circular(13),
              boxShadow: [BoxShadow(color: _teal.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            alignment: Alignment.center,
            child: const Text('ЛИД', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.5)),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Новый лид', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                Text(_nextNumber != null ? 'Номер присвоится: №$_nextNumber' : 'Определяем номер…',
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

  /// Живой предпросмотр в формате «№1-11:40 Дархан +7…».
  Widget _previewBar(bool dark) {
    final num = _nextNumber != null ? '№$_nextNumber' : '№—';
    final time = _hhmm(_apptTime) ?? '--:--';
    final name = _name.text.trim().isEmpty ? 'Имя' : _name.text.trim();
    final phone = _phone.text.trim();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [_teal.withValues(alpha: 0.14), _teal.withValues(alpha: 0.06)]),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: _teal.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        const Icon(Icons.bolt_rounded, size: 17, color: _teal),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$num-$time  $name${phone.isNotEmpty ? '  $phone' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: dark ? Colors.white : const Color(0xFF0E3B36)),
          ),
        ),
      ]),
    );
  }

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
                decoration: BoxDecoration(color: _teal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, size: 16, color: _teal),
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
      {IconData? icon, bool required = false, TextInputType? keyboard, bool digitsOnly = false, int maxLines = 1}) {
    final fill = dark ? const Color(0xFF232E36) : const Color(0xFFF4F6F8);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: c,
        keyboardType: keyboard,
        maxLines: maxLines,
        textInputAction: TextInputAction.next,
        inputFormatters: digitsOnly
            ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))]
            : (keyboard == TextInputType.phone ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\- ]'))] : null),
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
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: _teal, width: 1.5)),
        ),
        validator: required ? (v) => (v == null || v.trim().isEmpty) ? 'Укажите имя' : null : null,
      ),
    );
  }

  Widget _dateTile(bool dark, String label, DateTime? value, ValueChanged<DateTime?> onPick) {
    return _pickTile(dark,
        icon: Icons.calendar_month_rounded,
        label: label,
        value: value != null ? DateFormat('dd.MM.yyyy').format(value) : null, onTap: () async {
      final now = DateTime.now();
      final d = await showDatePicker(
        context: context,
        initialDate: value ?? now,
        firstDate: DateTime(now.year - 1),
        lastDate: DateTime(now.year + 3),
        builder: (ctx, child) => Theme(data: _pickerTheme(ctx), child: child!),
      );
      if (d != null) onPick(d);
    }, onClear: value != null ? () => onPick(null) : null);
  }

  Widget _timeTile(bool dark, String label, TimeOfDay? value, ValueChanged<TimeOfDay?> onPick) {
    return _pickTile(dark,
        icon: Icons.schedule_rounded, label: label, value: value != null ? _hhmm(value) : null, onTap: () async {
      final t = await showTimePicker(
        context: context,
        initialTime: value ?? TimeOfDay.now(),
        builder: (ctx, child) => Theme(
          data: _pickerTheme(ctx),
          child: MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
        ),
      );
      if (t != null) onPick(t);
    }, onClear: value != null ? () => onPick(null) : null);
  }

  ThemeData _pickerTheme(BuildContext ctx) =>
      Theme.of(ctx).copyWith(colorScheme: Theme.of(ctx).colorScheme.copyWith(primary: _teal));

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
          border: set ? Border.all(color: _teal.withValues(alpha: 0.4)) : null,
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: set ? _teal : Colors.grey),
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
          if (onClear != null) GestureDetector(onTap: onClear, child: Icon(Icons.close_rounded, size: 15, color: Colors.grey.shade500)),
        ]),
      ),
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
              backgroundColor: _teal,
              disabledBackgroundColor: _teal.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              elevation: 0,
            ),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.check_rounded, size: 21),
                    SizedBox(width: 8),
                    Text('Сохранить лид', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ]),
          ),
        ),
      ),
    );
  }
}
