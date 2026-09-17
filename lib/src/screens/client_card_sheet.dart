import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';
import 'package:intl/intl.dart';

import '../state/providers.dart';
import 'soft_ui.dart';

/// Карточка Telegram-клиента: телефон/страна/источник, статус сделки,
/// ответственный менеджер и передача чата. Данные — `contacts/{tg_<id>}`.
class ClientCardSheet {
  static Future<void> show(BuildContext context, {required String conversationId}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _ClientCardBody(conversationId: conversationId),
    );
  }
}

/// Статусы карточки: новый → в работе → счёт → оплачен / отказ.
const Map<String, String> kClientStatusLabels = {
  'new': 'Новый',
  'in_progress': 'В работе',
  'invoice': 'Счёт',
  'paid': 'Оплачен',
  'refused': 'Отказ',
};

const Map<String, String> _countryLabels = {'kz': 'Казахстан', 'ru': 'Россия', 'other': 'Другая'};

class _ClientCardBody extends ConsumerWidget {
  const _ClientCardBody({required this.conversationId});
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = FirebaseFirestore.instance.collection('contacts').doc(conversationId);
    return SafeArea(
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: doc.snapshots(),
        builder: (context, snap) {
          final d = snap.data?.data();
          if (d == null) {
            return const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final name = (d['name'] as String?) ?? conversationId;
          final username = (d['username'] as String?)?.trim();
          final phone = (d['phone'] as String?)?.trim();
          final country = d['country'] as String?;
          final source = (d['source'] as String?)?.trim();
          final status = (d['status'] as String?) ?? 'new';
          final transport = (d['transport'] as String?) ?? 'bot';
          final optIn = d['optIn'] != false;
          final responsibleId = d['responsibleId'] as String?;
          final responsibleName = (d['responsibleName'] as String?)?.trim();
          final createdAt = (d['createdAt'] as Timestamp?)?.toDate();

          return SingleChildScrollView(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: const Color(0xFF229ED9).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.telegram, color: Color(0xFF229ED9), size: 26),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(displayName(name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kInk)),
                      if (username != null && username.isNotEmpty)
                        GestureDetector(
                          onTap: () => _copy(context, '@$username'),
                          child: Text('@$username', style: const TextStyle(fontSize: 13, color: kSub, fontWeight: FontWeight.w600)),
                        ),
                    ]),
                  ),
                  _Chip(
                    label: transport == 'personal' ? 'Личный' : 'Бот',
                    bg: const Color(0xFF229ED9).withValues(alpha: 0.10),
                    fg: const Color(0xFF1C7FB0),
                  ),
                ]),
              ),
              if (!optIn)
                Container(
                  margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFBEDEC),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFC6403C).withValues(alpha: 0.3)),
                  ),
                  child: const Row(children: [
                    Icon(Iconsax.warning_2, size: 18, color: Color(0xFFC6403C)),
                    SizedBox(width: 9),
                    Expanded(
                      child: Text('Клиент заблокировал бота — сообщения не дойдут',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFFC6403C))),
                    ),
                  ]),
                ),

              // ── Реквизиты ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Column(children: [
                  _row(
                    context,
                    icon: Iconsax.call,
                    label: 'Телефон',
                    value: phone != null && phone.isNotEmpty ? '+$phone' : 'не поделился',
                    trailing: phone != null && phone.isNotEmpty && country != null
                        ? ClipOval(
                            child: Image.asset(country == 'kz' ? 'assets/kz.png' : 'assets/rus.png',
                                width: 22, height: 22, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                          )
                        : null,
                    onTap: phone != null && phone.isNotEmpty ? () => _copy(context, '+$phone') : null,
                  ),
                  _row(context, icon: Iconsax.global, label: 'Страна', value: _countryLabels[country] ?? '—'),
                  _row(context, icon: Iconsax.link_1, label: 'Источник', value: source == null || source.isEmpty || source == 'direct' ? 'прямой заход' : source),
                  if (createdAt != null)
                    _row(context, icon: Iconsax.calendar_1, label: 'Появился', value: DateFormat('dd.MM.yyyy HH:mm').format(createdAt)),
                ]),
              ),

              // ── Статус сделки ────────────────────────────────────────────
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text('Статус', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: kSub)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final e in kClientStatusLabels.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: status == e.key,
                        selectedColor: kTeal,
                        labelStyle: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: status == e.key ? Colors.white : kInk,
                        ),
                        onSelected: (_) => doc.set({'status': e.key, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true)),
                      ),
                  ],
                ),
              ),

              // ── Ответственный ────────────────────────────────────────────
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text('Ответственный', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: kSub)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      responsibleId == null ? 'Свободен — станет первый ответивший' : (responsibleName ?? 'Менеджер'),
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: responsibleId == null ? kSub : kInk,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _pickManager(context, ref),
                    icon: const Icon(Iconsax.arrow_swap_horizontal, size: 17),
                    label: Text(responsibleId == null ? 'Назначить' : 'Передать'),
                  ),
                ]),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context,
      {required IconData icon, required String label, required String value, Widget? trailing, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Icon(icon, size: 18, color: kSub),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 13.5, color: kSub)),
          const Spacer(),
          if (trailing != null) ...[trailing, const SizedBox(width: 7)],
          Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kInk)),
        ]),
      ),
    );
  }

  static void _copy(BuildContext context, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Скопировано: $value')));
  }

  /// Выбор менеджера для передачи чата → Cloud Function tgTransfer
  /// (смена responsibleId + запись в историю).
  Future<void> _pickManager(BuildContext context, WidgetRef ref) async {
    final managers = (ref.read(managersProvider).value ?? const <Map<String, dynamic>>[])
        .where((u) => u['isActive'] != false)
        .toList();
    if (managers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Список менеджеров пуст')));
      return;
    }
    final toUid = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Кому передать чат?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kInk)),
            ),
          ),
          for (final u in managers)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: kTeal.withValues(alpha: 0.15),
                child: Text(((u['name'] as String?)?.trim().isNotEmpty == true ? (u['name'] as String).trim()[0] : '?').toUpperCase(),
                    style: const TextStyle(color: kTealDeep, fontWeight: FontWeight.w700)),
              ),
              title: Text(((u['name'] as String?)?.trim().isNotEmpty == true ? (u['name'] as String).trim() : (u['email'] as String? ?? 'Менеджер')),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(sheet, u['id'] as String),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (toUid == null || !context.mounted) return;
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('tgTransfer')
          .call<Map<String, dynamic>>({'conversationId': conversationId, 'toUid': toUid});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Чат передан')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не передано: $e')));
      }
    }
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.bg, required this.fg});
  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: fg)),
    );
  }
}
