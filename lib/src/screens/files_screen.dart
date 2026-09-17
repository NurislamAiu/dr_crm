import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../data/firestore_chat_repository.dart';
import '../state/providers.dart';
import 'firebase_chats.dart';
import 'soft_ui.dart';

const _pageBg = Color(0xFFF2F2F7);

/// Файлы из переписок за день: кто прислал PDF (чеки, заключения) или фото.
///
/// Появился из ручной задачи «найди номера, кто прислал PDF за 3 часа»:
/// теперь это делается на экране — день листается стрелками, тип файла и
/// страна номера выбираются чипами, номера копируются кнопкой.
class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

/// Что ищем: PDF, фото или любые вложения.
enum _Kind { pdf, photo, any }

/// Страна номера: по коду. 77… — Казахстан, 79… — Россия.
enum _Country { all, kz, ru, other }

/// Строка результата: одно входящее сообщение с вложением.
class _Hit {
  _Hit({required this.chatId, required this.at, this.fileName, this.mime, this.mediaUrl});
  final String chatId;
  final DateTime at;
  final String? fileName;
  final String? mime;
  final String? mediaUrl;

  /// Заполняются после подгрузки диалога (имя и номер для tg_-чатов).
  String? name;
  String? phone;
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  DateTime _day = DateTime.now();
  _Kind _kind = _Kind.pdf;
  _Country _country = _Country.all;

  bool _loading = false;
  String? _error;
  List<_Hit> _hits = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  bool _matchKind(String type, String name, String mime) => switch (_kind) {
        _Kind.pdf => name.endsWith('.pdf') || mime.contains('pdf'),
        _Kind.photo => type == 'image' || mime.startsWith('image/'),
        _Kind.any => type == 'image' || type == 'audio' || type == 'document' || type == 'file' || name.isNotEmpty || mime.isNotEmpty,
      };

  static _Country _countryOf(String phone) {
    if (phone.startsWith('77')) return _Country.kz;
    if (phone.startsWith('79')) return _Country.ru;
    return _Country.other;
  }

  /// Входящие с вложениями за выбранный день. Запрос — только диапазон по
  /// createdAt (индексы не нужны), остальное отсеивается на телефоне.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final start = DateTime(_day.year, _day.month, _day.day);
      final snap = await FirebaseFirestore.instance
          .collection('messages')
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where('createdAt', isLessThan: Timestamp.fromDate(start.add(const Duration(days: 1))))
          .orderBy('createdAt', descending: true)
          .limit(4000)
          .get();

      final hits = <_Hit>[];
      for (final d in snap.docs) {
        final x = d.data();
        if (x['direction'] != 'inbound') continue;
        final name = (x['fileName'] as String? ?? '').toLowerCase();
        final mime = (x['mediaContentType'] as String? ?? '').toLowerCase();
        final type = (x['type'] as String? ?? '').toLowerCase();
        if (!_matchKind(type, name, mime)) continue;
        final at = (x['createdAt'] as Timestamp?)?.toDate();
        if (at == null) continue;
        hits.add(_Hit(
          chatId: (x['conversationId'] ?? x['chatId'] ?? '') as String,
          at: at,
          fileName: x['fileName'] as String?,
          mime: x['mediaContentType'] as String?,
          mediaUrl: (x['mediaUrl'] ?? x['contentUri']) as String?,
        ));
      }

      // Имя и номер — из диалога: у tg_-чатов номер в id не лежит.
      final repo = ref.read(firestoreChatRepositoryProvider);
      final ids = hits.map((h) => h.chatId).where((id) => id.isNotEmpty).toSet().take(60);
      final convs = <String, FsConversation?>{};
      for (final id in ids) {
        try {
          convs[id] = await repo.watchConversation(id).first;
        } catch (_) {
          convs[id] = null;
        }
      }
      // Личные чаты владельца выкидываем из выдачи целиком: этот экран
      // открывает переписку напрямую (_openChat), и без проверки менеджер
      // заходил бы в забранный чат через присланный там файл — минуя список,
      // где чат уже скрыт.
      final myUid = ref.read(appConfigProvider).userId;
      hits.removeWhere((h) {
        final owner = convs[h.chatId]?.privateOwnerUid;
        return owner != null && owner != myUid;
      });
      for (final h in hits) {
        final c = convs[h.chatId];
        h.name = c?.name;
        h.phone = c?.phone ?? (h.chatId.startsWith('tg_') ? null : h.chatId.replaceAll(RegExp(r'\D'), ''));
      }

      if (!mounted) return;
      setState(() {
        _hits = hits;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<_Hit> get _filtered => _country == _Country.all
      ? _hits
      : _hits.where((h) => _countryOf(h.phone ?? '') == _country).toList();

  Future<void> _openChat(_Hit h) async {
    final c = await ref.read(firestoreChatRepositoryProvider).watchConversation(h.chatId).first;
    if (!mounted || c == null) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FirebaseChatScreen(conversation: c)));
  }

  Future<void> _copyNumbers() async {
    final numbers = _filtered.map((h) => h.phone).whereType<String>().where((p) => p.isNotEmpty).toSet();
    if (numbers.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: numbers.map((p) => '+$p').join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Скопировано номеров: ${numbers.length}')));
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2025, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _day = picked);
      _load();
    }
  }

  void _shiftDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(DateTime.now())) return;
    setState(() => _day = next);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    final numbers = list.map((h) => h.phone).whereType<String>().where((p) => p.isNotEmpty).toSet();
    return Scaffold(
      backgroundColor: _pageBg,
      body: Column(children: [
        SoftHeader(
          color: kTeal,
          colorDeep: kTealDeep,
          title: 'Файлы из чатов',
          dateLabel: 'Кто прислал PDF или фото за день',
          showBack: true,
          actions: const [],
        ),
        Expanded(
          child: Container(
            transform: Matrix4.translationValues(0, -22, 0),
            decoration: const BoxDecoration(
              color: _pageBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(15, 22, 15, 28),
              children: [
                _dayCard(),
                const SizedBox(height: 12),
                _filtersCard(),
                const SizedBox(height: 12),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  _card(
                    child: Column(children: [
                      Text('Не загрузилось: $_error', style: const TextStyle(fontSize: 13, color: kSub)),
                      const SizedBox(height: 10),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: kTeal),
                        onPressed: _load,
                        child: const Text('Повторить'),
                      ),
                    ]),
                  )
                else if (list.isEmpty)
                  _card(
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(
                        child: Text('За этот день таких файлов нет', style: TextStyle(fontSize: 13.5, color: kSub)),
                      ),
                    ),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Row(children: [
                      Text('Файлов: ${list.length} · номеров: ${numbers.length}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kInk)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _copyNumbers,
                        icon: const Icon(Iconsax.copy, size: 16),
                        label: const Text('Скопировать'),
                      ),
                    ]),
                  ),
                  _card(
                    child: Column(children: [
                      for (final (i, h) in list.indexed) ...[
                        if (i > 0) const Divider(height: 1, color: Color(0xFFF0F2F4)),
                        _row(h),
                      ],
                    ]),
                  ),
                ],
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _dayCard() {
    final today = _sameDay(_day, DateTime.now());
    return _card(
      child: Row(children: [
        IconButton(onPressed: () => _shiftDay(-1), icon: const Icon(Icons.chevron_left_rounded, size: 28)),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _pickDay,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                Text(today ? 'Сегодня' : weekdayDateRu(_day),
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: kInk)),
                const SizedBox(height: 2),
                const Text('нажмите, чтобы выбрать в календаре', style: TextStyle(fontSize: 11.5, color: kSub)),
              ]),
            ),
          ),
        ),
        IconButton(
          onPressed: today ? null : () => _shiftDay(1),
          icon: const Icon(Icons.chevron_right_rounded, size: 28),
        ),
      ]),
    );
  }

  Widget _filtersCard() => _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _chip('PDF', _kind == _Kind.pdf, () => setState(() => _kind = _Kind.pdf)),
            const SizedBox(width: 8),
            _chip('Фото', _kind == _Kind.photo, () => setState(() => _kind = _Kind.photo)),
            const SizedBox(width: 8),
            _chip('Все файлы', _kind == _Kind.any, () => setState(() => _kind = _Kind.any)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _chip('Все номера', _country == _Country.all, () => setState(() => _country = _Country.all)),
            const SizedBox(width: 8),
            _chip('KZ', _country == _Country.kz, () => setState(() => _country = _Country.kz)),
            const SizedBox(width: 8),
            _chip('RU', _country == _Country.ru, () => setState(() => _country = _Country.ru)),
            const SizedBox(width: 8),
            _chip('Другие', _country == _Country.other, () => setState(() => _country = _Country.other)),
          ]),
        ]),
      );

  Widget _chip(String label, bool active, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? kTeal.withValues(alpha: 0.13) : const Color(0xFFF2F5F7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: active ? kTealDeep : kSub)),
        ),
      );

  Widget _row(_Hit h) {
    final time =
        '${h.at.hour.toString().padLeft(2, '0')}:${h.at.minute.toString().padLeft(2, '0')}';
    final phone = h.phone == null || h.phone!.isEmpty ? null : '+${h.phone}';
    final title = (h.name ?? '').isNotEmpty ? h.name! : (phone ?? h.chatId);
    final mime = (h.mime ?? '').toLowerCase();
    final isPdf = (h.fileName ?? '').toLowerCase().endsWith('.pdf') || mime.contains('pdf');
    final isPhoto = mime.startsWith('image/');
    return InkWell(
      onTap: () => _openChat(h),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: (isPdf ? const Color(0xFFC6403C) : kTeal).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isPdf ? Iconsax.document_text : (isPhoto ? Iconsax.image : Iconsax.document),
              size: 19,
              color: isPdf ? const Color(0xFFC6403C) : kTealDeep,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: kInk)),
              const SizedBox(height: 2),
              Text(
                [
                  if (phone != null && phone != title) phone,
                  h.fileName ?? (isPhoto ? 'фото' : 'файл'),
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: kSub),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Text(time, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: kSub)),
          const Icon(Icons.chevron_right_rounded, size: 20, color: kSub),
        ]),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 5))],
        ),
        child: child,
      );
}
