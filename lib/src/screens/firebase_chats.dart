import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';

import 'package:iconsax/iconsax.dart';

import '../data/firestore_chat_repository.dart';
import '../data/channel_status_service.dart';
import '../data/presence_service.dart';
import '../data/quick_replies_service.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'lead_sheet.dart';
import 'massage_sheet.dart';
import 'soft_ui.dart';
import 'vip_client_sheet.dart';

const _chatsPageBg = Color(0xFFF1F8F6);

/// Список чатов — «мягкий» стиль: тил-шапка со скруглением, белый лист,
/// карточки с флаг-аватарами. VIP-чаты получают аватар assets/vip.png,
/// лиды — бейдж-молнию на флаге.
class FirebaseConversationsScreen extends ConsumerStatefulWidget {
  const FirebaseConversationsScreen({super.key});

  @override
  ConsumerState<FirebaseConversationsScreen> createState() => _FirebaseConversationsScreenState();
}

/// Фильтр списка чатов.
enum _ChatFilter { all, unread, lead, massage, vip }

class _FirebaseConversationsScreenState extends ConsumerState<FirebaseConversationsScreen> {
  final _search = TextEditingController();
  String _query = '';
  _ChatFilter _filter = _ChatFilter.all;

  @override
  void initState() {
    super.initState();
    // Один раз проверяем наличие vip.png: иначе каждый VIP-тайл при скролле
    // безуспешно грузит ассет заново (джанк из-за асинхронных исключений).
    if (vipAssetExists == null) {
      rootBundle.load('assets/vip.png').then((_) {
        vipAssetExists = true;
        if (mounted) setState(() {});
      }).catchError((_) {
        vipAssetExists = false;
      });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vipPhones = ref.watch(vipPhonesProvider);
    final leadPhones = ref.watch(leadPhonesProvider);
    final massagePhones = ref.watch(massagePhonesProvider);
    final leadsToday = ref.watch(leadsTodayCountProvider);

    // Статистика дня — в шапке (стеклянные карточки на тил-фоне).
    final items = ref.watch(firebaseConversationsProvider).value ?? const <FsConversation>[];
    final todayChats = items.where((c) => _isToday(c.lastMessageAt)).toList();
    final answered = todayChats.where((c) => c.unreadCount == 0).length;

    final conv = ref.watch(firebaseConversationsProvider);
    // Состояние WhatsApp-канала (Wazzup): предупреждаем, если номер отвалился.
    final channel = ref.watch(channelStatusProvider).value;

    // Шапка как в WhatsApp: прячется при скролле вниз, возвращается при
    // скролле вверх (floating + snap).
    final header = SliverAppBar(
      automaticallyImplyLeading: false,
      primary: false,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      toolbarHeight: 0,
      floating: true,
      snap: true,
      expandedHeight: MediaQuery.of(context).padding.top + 292,
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.pin,
        background: SoftHeader(
          color: kTeal,
          colorDeep: kTealDeep,
          title: 'Чаты',
          dateLabel: weekdayDateRu(DateTime.now()),
          actions: const [_FbOnlineBadge()],
          strip: Column(children: [
            _searchBar(),
            const SizedBox(height: 12),
            Row(children: [
              HeaderStat(value: '$leadsToday', label: 'лидов сегодня'),
              const SizedBox(width: 9),
              HeaderStat(
                value: todayChats.isEmpty ? '—' : '$answered/${todayChats.length}',
                label: 'отвечено чатов',
              ),
            ]),
            const SizedBox(height: 12),
            _filterChips(items, vipPhones, leadPhones, massagePhones),
          ]),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: _chatsPageBg,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          header,
          ...conv.when(
            loading: () => [const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))],
            // Переподключение идёт само 30 секунд; если не помогло — кнопка.
            error: (e, _) => [
              SliverFillRemaining(
                hasScrollBody: false,
                child: _msg(
                  Iconsax.cloud_cross,
                  'Нет связи с сервером',
                  'Не удалось подключиться за 30 секунд.\nПроверьте интернет и попробуйте снова.',
                  onRetry: () => ref.invalidate(firebaseConversationsProvider),
                ),
              ),
            ],
            data: (items) {
              // Поиск: по имени, номеру (цифрам) и тексту последнего сообщения.
              final q = _query.trim().toLowerCase();
              final qDigits = q.replaceAll(RegExp(r'\D'), '');
              // Заблокированные скрыты из списка, но находятся поиском.
              var filtered = q.isEmpty
                  ? items.where((c) => !c.blocked).toList()
                  : items.where((c) {
                      final digits = (c.phone ?? c.id).replaceAll(RegExp(r'\D'), '');
                      return c.name.toLowerCase().contains(q) ||
                          (qDigits.isNotEmpty && digits.contains(qDigits)) ||
                          (c.preview ?? '').toLowerCase().contains(q);
                    }).toList();
              // Вкладка-фильтр: непрочитанные / лиды / массаж / VIP.
              filtered = filtered.where((c) => _matches(c, vipPhones, leadPhones, massagePhones)).toList();
              if (filtered.isEmpty) {
                return [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: q.isNotEmpty
                        ? _msg(Iconsax.search_normal, 'Ничего не найдено', 'Попробуйте другое имя или номер')
                        : _filter != _ChatFilter.all
                            ? _msg(Iconsax.filter, 'Здесь пусто', 'В этой вкладке сейчас нет чатов')
                            : _msg(Iconsax.message, 'Пока нет чатов', 'Входящие появятся здесь'),
                  ),
                ];
              }
              return [
                if (channel != null && !channel.isActive && !channel.isUnknown)
                  SliverToBoxAdapter(child: _channelBanner(channel)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(15, 14, 15, 24),
                  sliver: SliverList.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final c = filtered[i];
                      final digits = (c.phone ?? c.id).replaceAll(RegExp(r'\D'), '');
                      return _tile(context, c,
                          isVip: vipPhones.contains(digits),
                          isLead: leadPhones.contains(digits),
                          isMassage: massagePhones.contains(digits));
                    },
                  ),
                ),
              ];
            },
          ),
        ],
      ),
    );
  }

  /// Подходит ли чат под выбранную вкладку.
  bool _matches(FsConversation c, Set<String> vip, Set<String> lead, Set<String> mass) {
    final digits = (c.phone ?? c.id).replaceAll(RegExp(r'\D'), '');
    return switch (_filter) {
      _ChatFilter.all => true,
      _ChatFilter.unread => c.unreadCount > 0 || c.manualUnread,
      _ChatFilter.lead => lead.contains(digits),
      _ChatFilter.massage => mass.contains(digits),
      _ChatFilter.vip => vip.contains(digits),
    };
  }

  /// Сколько чатов попадает во вкладку (для счётчика).
  int _countFor(_ChatFilter f, List<FsConversation> items, Set<String> vip, Set<String> lead, Set<String> mass) {
    final old = _filter;
    _filter = f;
    final n = items.where((c) => !c.blocked && _matches(c, vip, lead, mass)).length;
    _filter = old;
    return n;
  }

  /// Вкладки-фильтры со счётчиками (в шапке, горизонтальный скролл).
  Widget _filterChips(List<FsConversation> items, Set<String> vip, Set<String> lead, Set<String> mass) {
    const tabs = <(_ChatFilter, String)>[
      (_ChatFilter.all, 'Все'),
      (_ChatFilter.unread, 'Непрочитанные'),
      (_ChatFilter.lead, 'Лиды'),
      (_ChatFilter.massage, 'Массаж'),
      (_ChatFilter.vip, 'VIP'),
    ];
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 7),
        itemBuilder: (context, i) {
          final (f, label) = tabs[i];
          final sel = _filter == f;
          final n = _countFor(f, items, vip, lead, mass);
          return Material(
            color: sel ? Colors.white : Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _filter = f),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                          color: sel ? kTealDeep : Colors.white)),
                  if (n > 0) ...[
                    const SizedBox(width: 5),
                    Text('$n',
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: sel ? kTealDeep.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.7))),
                  ],
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Меню по долгому нажатию на чат (как в WhatsApp).
  Future<void> _chatActions(FsConversation c, bool unread) async {
    final repo = ref.read(firestoreChatRepositoryProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(displayName(c.name),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kInk)),
            ),
          ),
          ListTile(
            leading: const Icon(Iconsax.copy, color: kTealDeep),
            title: const Text('Скопировать номер', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(sheet, 'copy'),
          ),
          ListTile(
            leading: Icon(unread ? Iconsax.tick_circle : Iconsax.message_notif, color: kTealDeep),
            title: Text(unread ? 'Отметить прочитанным' : 'Отметить непрочитанным',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(sheet, unread ? 'read' : 'unread'),
          ),
          ListTile(
            leading: Icon(c.blocked ? Icons.lock_open_rounded : Icons.block_rounded,
                color: c.blocked ? kTealDeep : const Color(0xFFC6403C)),
            title: Text(c.blocked ? 'Разблокировать' : 'Заблокировать',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(sheet, 'block'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (action == null) return;
    try {
      switch (action) {
        case 'copy':
          if (mounted) await copyPhone(context, c.phone ?? c.id);
        case 'unread':
          await repo.markUnread(c.id);
        case 'read':
          await repo.markRead(c.id);
        case 'block':
          await repo.setBlocked(c.id, !c.blocked);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  /// Баннер «WhatsApp отключён» — сообщения сейчас не уходят.
  Widget _channelBanner(ChannelStatus ch) {
    return Container(
      margin: const EdgeInsets.fromLTRB(15, 14, 15, 0),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFFBEDEC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFC6403C).withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        const Icon(Iconsax.warning_2, size: 20, color: Color(0xFFC6403C)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ch.label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFFC6403C))),
            const SizedBox(height: 2),
            const Text('Сообщения сейчас не отправляются. Проверьте подключение номера в Wazzup.',
                style: TextStyle(fontSize: 12, color: Color(0xFF8C3A36))),
          ]),
        ),
      ]),
    );
  }

  /// Стеклянная поисковая строка на тил-шапке: имя, номер или текст сообщения.
  Widget _searchBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(16),
      ),
      child: TextField(
        controller: _search,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        cursorColor: Colors.white,
        style: const TextStyle(fontSize: 14.5, color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Поиск: имя или номер',
          hintStyle: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.75)),
          filled: false,
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 13),
          prefixIcon: Icon(Iconsax.search_normal_1, size: 19, color: Colors.white.withValues(alpha: 0.85)),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Iconsax.close_circle, size: 19, color: Colors.white.withValues(alpha: 0.85)),
                  tooltip: 'Очистить',
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                    FocusScope.of(context).unfocus();
                  },
                ),
        ),
      ),
    );
  }

  /// Время в списке чатов: сегодня — «14:32», вчера — «Вчера», раньше — дата.
  static String _listTime(DateTime? d) {
    if (d == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return DateFormat('HH:mm').format(d);
    if (diff == 1) return 'Вчера';
    if (d.year == now.year) return DateFormat('dd.MM').format(d);
    return DateFormat('dd.MM.yy').format(d);
  }

  /// Имя менеджера, ответившего последним (для превью в списке).
  String? _lastAuthor(FsConversation c) {
    if (!c.lastOutbound) return null;
    final uid = c.lastAuthorId;
    // Ответ не из нашего приложения — имя приходит от Wazzup.
    if (uid == null || uid.isEmpty) {
      final wz = (c.lastAuthorName ?? '').trim();
      return wz.isEmpty ? null : wz.split(' ').first;
    }
    if (uid == 'auto') return 'Автоответ';
    final managers = ref.watch(managersProvider).value ?? const <Map<String, dynamic>>[];
    for (final u in managers) {
      if (u['id'] == uid) {
        final name = ((u['name'] as String?) ?? '').trim();
        if (name.isNotEmpty) return name.split(' ').first;
      }
    }
    return uid == ref.read(appConfigProvider).userId ? 'Вы' : null;
  }

  static bool _isToday(DateTime? d) {
    if (d == null) return false;
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  Widget _tile(BuildContext context, FsConversation c,
      {required bool isVip, required bool isLead, bool isMassage = false}) {
    final unread = c.unreadCount > 0 || c.manualUnread;
    final time = _listTime(c.lastMessageAt);
    final lastAuthor = _lastAuthor(c);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FirebaseChatScreen(conversation: c))),
          onLongPress: () => _chatActions(c, unread),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 13, 14, 13),
            child: Row(children: [
              _ChatAvatar(phone: c.phone ?? c.id, isVip: isVip, isLead: isLead),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(displayName(c.name),
                            maxLines: 1,
                            style: const TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                color: kInk,
                                letterSpacing: -0.2,
                                height: 1.0)),
                      ),
                    ),
                    // Метка сохранённого клиента: VIP — золотая, лид — тил.
                    if (c.blocked)
                      const _TagChip(label: 'БЛОК', bg: Color(0xFFEDEDEF), fg: Color(0xFF74747C))
                    else if (isVip)
                      const _TagChip(label: 'VIP', bg: Color(0xFFFDF3D7), fg: Color(0xFF9A7208))
                    else if (isLead)
                      const _TagChip(label: 'ЛИД', bg: Color(0xFFDFF4EF), fg: kTealDeep),
                    const Spacer(),
                    const SizedBox(width: 8),
                    Text(time,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                            color: unread ? kTealDeep : kSub,
                            fontFeatures: const [FontFeature.tabularFigures()])),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(
                      child: Row(children: [
                        // Кто ответил последним — как «Вы:» в WhatsApp.
                        if (lastAuthor != null)
                          Text('$lastAuthor: ',
                              style: const TextStyle(fontSize: 12.5, color: kTealDeep, fontWeight: FontWeight.w700)),
                        Expanded(
                          child: Text(c.preview ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: kSub, fontWeight: unread ? FontWeight.w600 : FontWeight.w400)),
                        ),
                      ]),
                    ),
                    if (unread)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: EdgeInsets.symmetric(horizontal: c.unreadCount > 0 ? 7 : 6, vertical: c.unreadCount > 0 ? 2 : 6),
                        decoration: BoxDecoration(color: kTeal, borderRadius: BorderRadius.circular(10)),
                        child: c.unreadCount > 0
                            ? Text('${c.unreadCount}',
                                style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700))
                            : const SizedBox.shrink(), // ручная отметка — просто точка
                      ),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _msg(IconData i, String t, String s, {VoidCallback? onRetry}) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(22)),
              child: Icon(i, size: 34, color: kTeal),
            ),
            const SizedBox(height: 16),
            Text(t, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 6),
            Text(s, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: kSub)),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              SizedBox(
                width: 190,
                height: 46,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: kTealDeep,
                    minimumSize: const Size(190, 46),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Подключиться заново',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  onPressed: onRetry,
                ),
              ),
            ],
          ]),
        ),
      );
}

/// Мини-метка «VIP» / «ЛИД» рядом с именем в списке чатов.
class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.bg, required this.fg});
  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(7)),
      child: Text(label,
          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: fg, letterSpacing: 0.4)),
    );
  }
}

/// Есть ли assets/vip.png (проверяется один раз при старте экрана чатов).
bool? vipAssetExists;

/// Аватар чата: обычный — флаг страны; VIP — assets/vip.png (фолбэк — корона);
/// лид — флаг с тил-бейджем-молнией.
class _ChatAvatar extends StatelessWidget {
  const _ChatAvatar({required this.phone, required this.isVip, required this.isLead});
  final String phone;
  final bool isVip;
  final bool isLead;

  @override
  Widget build(BuildContext context) {
    const size = 50.0;
    final radius = BorderRadius.circular(size * 0.3);

    if (isVip) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: const Color(0xFFE7C14A), width: 1.4),
          boxShadow: [BoxShadow(color: const Color(0xFFE7C14A).withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 3))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.3 - 1.4),
          // Ассет грузим только если он точно есть — иначе фолбэк-корона
          // (повторные неудачные загрузки лагали при скролле).
          child: vipAssetExists == true
              ? Image.asset('assets/vip.png', fit: BoxFit.cover)
              : Container(
                  color: const Color(0xFFB81F2D),
                  alignment: Alignment.center,
                  child: const Icon(Iconsax.crown_1, color: Color(0xFFFFE9A8), size: 26),
                ),
        ),
      );
    }

    final flag = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: Colors.black.withValues(alpha: 0.07)),
        image: DecorationImage(image: AssetImage(flagAsset(phone)), fit: BoxFit.cover),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 3))],
      ),
    );
    if (!isLead) return flag;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        flag,
        Positioned(
          right: -4,
          bottom: -4,
          child: Container(
            width: 21,
            height: 21,
            decoration: BoxDecoration(
              color: kTeal,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: const Icon(Iconsax.flash_1, color: Colors.white, size: 11),
          ),
        ),
      ]),
    );
  }
}

/// «N в сети» (presence из Firestore). Тап — список имён.
class _FbOnlineBadge extends ConsumerWidget {
  const _FbOnlineBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Кэшированный provider вместо StreamBuilder — без лишних подписок.
    final online = ref.watch(presenceUsersProvider).value ?? const <PresenceUser>[];
    return Builder(
      builder: (context) {
        if (online.isEmpty) return const SizedBox.shrink();
        // Стеклянная пилюля на тил-шапке.
        return Material(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(15),
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: () => _showList(context, ref, online),
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              alignment: Alignment.center,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF6BF29B), shape: BoxShape.circle)),
                const SizedBox(width: 7),
                Text('${online.length} в сети',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
              ]),
            ),
          ),
        );
      },
    );
  }

  void _showList(BuildContext context, WidgetRef ref, List<PresenceUser> online) {
    final me = ref.read(appConfigProvider).userId;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(children: [
              Container(width: 9, height: 9, decoration: const BoxDecoration(color: Color(0xFF2ECC71), shape: BoxShape.circle)),
              const SizedBox(width: 9),
              Text('В системе сейчас — ${online.length}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
          ),
          const Divider(height: 1),
          for (final u in online)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.brand.withValues(alpha: 0.15),
                child: Text((u.name.isNotEmpty ? u.name[0] : '?').toUpperCase(), style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w700)),
              ),
              title: Text(u.name.isEmpty ? 'Менеджер' : u.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: u.uid == me ? const Text('вы', style: TextStyle(color: AppColors.brand, fontWeight: FontWeight.w700)) : null,
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Переписка одного чата из Firestore + отправка через Cloud Function.
class FirebaseChatScreen extends ConsumerStatefulWidget {
  const FirebaseChatScreen({super.key, required this.conversation});
  final FsConversation conversation;

  @override
  ConsumerState<FirebaseChatScreen> createState() => _FirebaseChatScreenState();
}

class _FirebaseChatScreenState extends ConsumerState<FirebaseChatScreen> {
  final _input = TextEditingController();
  bool _sending = false;
  bool _hasText = false;

  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  int _recSeconds = 0;
  Timer? _recTimer;
  String? _recPath;

  FsMessage? _replyTo; // сообщение, на которое отвечаем

  // Блокировка контакта (скрытие из списка, без пушей/автоответов).
  late bool _blocked = widget.conversation.blocked;

  Future<void> _toggleBlock() async {
    final block = !_blocked;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(block ? 'Заблокировать контакта?' : 'Разблокировать контакта?'),
        content: Text(block
            ? 'Чат скроется из списка (найти можно поиском), пуши и автоответы для этого контакта отключатся. Сообщения продолжат сохраняться.'
            : 'Чат вернётся в список, пуши и автоответы снова заработают.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: block ? const Color(0xFFC6403C) : AppColors.brand),
            onPressed: () => Navigator.pop(d, true),
            child: Text(block ? 'Заблокировать' : 'Разблокировать'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(firestoreChatRepositoryProvider).setBlocked(widget.conversation.id, block);
      if (mounted) {
        setState(() => _blocked = block);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(block ? 'Контакт заблокирован' : 'Контакт разблокирован')),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  @override
  void initState() {
    super.initState();
    _input.addListener(() {
      final has = _input.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    ref.read(firestoreChatRepositoryProvider).markRead(widget.conversation.id).catchError((_) {});
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    _recorder.dispose();
    _input.dispose();
    super.dispose();
  }

  /// Текст, который уходит клиенту после звонка (обратно не звонить).
  static const _afterCallText =
      'Мы звонили Вам из клиники DR.TOITAYEV. Пожалуйста, не перезванивайте на этот номер — '
      'напишите нам сюда, в WhatsApp, и мы всё решим в чате.';

  Future<void> _callPhone(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri.parse('tel:$digits');
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw Exception('нет приложения для звонка');
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось позвонить: $e')));
      return;
    }
    // Возвращаемся в приложение — спрашиваем, чем закончился звонок.
    if (!mounted) return;
    await _askCallResult(phone);
  }

  /// Итог звонка: отметка в переписке + сообщение «пишите в чат».
  Future<void> _askCallResult(String phone) async {
    final res = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3))),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Чем закончился звонок?', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, color: kInk)),
            ),
          ),
          ListTile(
            leading: const Icon(Iconsax.call_calling, color: Color(0xFF23A35F)),
            title: const Text('Дозвонился', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Отметить в переписке'),
            onTap: () => Navigator.pop(sheet, 'answered'),
          ),
          ListTile(
            leading: const Icon(Iconsax.call_slash, color: Color(0xFFC6403C)),
            title: const Text('Не ответил', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Отметить и написать «пишите в чат»'),
            onTap: () => Navigator.pop(sheet, 'noAnswer'),
          ),
          ListTile(
            leading: const Icon(Iconsax.close_circle, color: kSub),
            title: const Text('Не записывать', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(sheet),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (res == null || !mounted) return;

    final cfg = ref.read(appConfigProvider);
    final repo = ref.read(firestoreChatRepositoryProvider);
    try {
      await repo.logCall(
        chatId: widget.conversation.id,
        result: res,
        authorId: cfg.userId ?? '',
        authorName: cfg.userName ?? '',
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не записалось: $e')));
    }
    if (res != 'noAnswer' || !mounted) return;

    // Предлагаем сразу отправить клиенту сообщение.
    final send = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Отправить сообщение?'),
        content: const Text(_afterCallText),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Не надо')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kTeal),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Отправить'),
          ),
        ],
      ),
    );
    if (send != true) return;
    try {
      await repo.sendText(phone: phone, text: _afterCallText, name: widget.conversation.name);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    }
  }

  Future<void> _startRec() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет доступа к микрофону')));
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      _recPath = path;
      setState(() {
        _recording = true;
        _recSeconds = 0;
      });
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recSeconds++);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Запись не началась: $e')));
    }
  }

  Future<void> _stopRecAndSend() async {
    _recTimer?.cancel();
    final tooShort = _recSeconds < 1;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {}
    setState(() => _recording = false);
    if (path == null || tooShort) {
      if (tooShort && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Слишком коротко')));
      return;
    }
    setState(() => _sending = true);
    try {
      final bytes = await File(path).readAsBytes();
      await ref.read(firestoreChatRepositoryProvider).sendMedia(
            phone: widget.conversation.phone ?? widget.conversation.id,
            bytes: bytes,
            fileName: 'voice.m4a',
            contentType: 'audio/mp4',
            kind: 'audio',
            name: widget.conversation.name,
          );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Голосовое не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _cancelRec() async {
    _recTimer?.cancel();
    try {
      await _recorder.stop();
      if (_recPath != null) {
        final f = File(_recPath!);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    if (mounted) setState(() => _recording = false);
  }

  Future<void> _pickAndSend() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Фото из галереи'), onTap: () => Navigator.pop(s, 'gallery')),
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Камера'), onTap: () => Navigator.pop(s, 'camera')),
          ListTile(leading: const Icon(Icons.attach_file), title: const Text('Файл'), onTap: () => Navigator.pop(s, 'file')),
        ]),
      ),
    );
    if (choice == null) return;

    List<int>? bytes;
    String? fileName;
    String? mime;
    String kind = 'document';
    try {
      if (choice == 'gallery' || choice == 'camera') {
        final x = await ImagePicker().pickImage(source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery, imageQuality: 85);
        if (x == null) return;
        bytes = await x.readAsBytes();
        fileName = x.name;
        mime = x.mimeType ?? 'image/jpeg';
        kind = 'image';
      } else {
        final res = await FilePicker.platform.pickFiles(withData: true);
        final f = res?.files.isNotEmpty == true ? res!.files.first : null;
        if (f == null || f.bytes == null) return;
        bytes = f.bytes!;
        fileName = f.name;
        mime = 'application/octet-stream';
        kind = 'document';
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось выбрать: $e')));
      return;
    }

    setState(() => _sending = true);
    try {
      await ref.read(firestoreChatRepositoryProvider).sendMedia(
            phone: widget.conversation.phone ?? widget.conversation.id,
            bytes: bytes,
            fileName: fileName,
            contentType: mime,
            kind: kind,
            name: widget.conversation.name,
          );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Медиа отправлено')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final reply = _replyTo;
    setState(() {
      _sending = true;
      _replyTo = null;
    });
    _input.clear();
    try {
      await ref.read(firestoreChatRepositoryProvider).sendText(
            phone: widget.conversation.phone ?? widget.conversation.id,
            text: text,
            name: widget.conversation.name,
            refMessageId: reply?.id,
            replyToText: reply?.text,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
        _input.text = text;
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showMessageActions(FsMessage m) {
    // Сообщение в очереди ещё не ушло — его можно только снять с отправки.
    final canEditDelete = m.isOutbound &&
        !m.isDeleted &&
        (m.status == 'sent' || m.status == 'delivered' || m.status == 'read' || m.status == 'accepted' || m.status == 'queued');
    if (m.isDeleted) return;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.reply_rounded),
            title: const Text('Ответить'),
            onTap: () {
              Navigator.pop(sheet);
              setState(() => _replyTo = m);
            },
          ),
          if (m.text != null && m.text!.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Копировать'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.text!));
                Navigator.pop(sheet);
              },
            ),
          if (canEditDelete && m.type == 'text')
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Изменить'),
              onTap: () {
                Navigator.pop(sheet);
                _editMessage(m);
              },
            ),
          if (canEditDelete)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Удалить', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(sheet);
                _deleteMessage(m);
              },
            ),
        ]),
      ),
    );
  }

  Future<void> _editMessage(FsMessage m) async {
    final c = TextEditingController(text: m.text ?? '');
    final newText = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Изменить сообщение'),
        content: TextField(controller: c, minLines: 1, maxLines: 6, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Сохранить')),
        ],
      ),
    );
    c.dispose();
    if (newText == null || newText.isEmpty || newText == m.text) return;
    try {
      await ref.read(firestoreChatRepositoryProvider).editText(messageId: m.id, text: newText);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не изменено: $e')));
    }
  }

  Future<void> _deleteMessage(FsMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Удалить сообщение?'),
        content: const Text('Будет удалено и у клиента в WhatsApp.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(d, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(firestoreChatRepositoryProvider).deleteMessage(m.id);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалено: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final phone = widget.conversation.phone ?? widget.conversation.id;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: const BoxDecoration(shape: BoxShape.circle),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(flagAsset(phone), fit: BoxFit.cover),
          ),
          const SizedBox(width: 10),
          // FittedBox: номер/имя ужимается под ширину, а не режется в «…».
          Expanded(
            // Долгое нажатие по номеру — копирование.
            child: GestureDetector(
              onLongPress: () => copyPhone(context, phone),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(displayName(widget.conversation.name),
                    maxLines: 1, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_rounded, color: AppColors.brand),
            tooltip: 'Позвонить',
            onPressed: () => _callPhone(phone),
          ),
          // ЛИД / VIP / блокировка — в аккуратном меню «⋮».
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, size: 22),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (v) {
              switch (v) {
                case 'copy':
                  copyPhone(context, phone);
                case 'lead':
                  LeadSheet.show(context, name: widget.conversation.name, phone: phone);
                case 'massage':
                  MassageSheet.show(context, name: widget.conversation.name, phone: phone);
                case 'vip':
                  VipClientSheet.show(context, name: widget.conversation.name, phone: phone);
                case 'block':
                  _toggleBlock();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'lead',
                child: Row(children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: const Color(0xFF13B0A0).withValues(alpha: 0.13), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Iconsax.flash_1, size: 17, color: Color(0xFF0E8F82)),
                  ),
                  const SizedBox(width: 12),
                  const Text('Создать лид', style: TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
              PopupMenuItem(
                value: 'copy',
                child: Row(children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: kSub.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Iconsax.copy, size: 17, color: kSub),
                  ),
                  const SizedBox(width: 12),
                  const Text('Скопировать номер', style: TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
              PopupMenuItem(
                value: 'massage',
                child: Row(children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: const Color(0xFFE3A008).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Iconsax.health, size: 17, color: Color(0xFF8C5F04)),
                  ),
                  const SizedBox(width: 12),
                  const Text('Записать на массаж', style: TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
              PopupMenuItem(
                value: 'vip',
                child: Row(children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: const Color(0xFFE23744).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                    child: const Icon(Iconsax.crown_1, size: 17, color: Color(0xFFD11E31)),
                  ),
                  const SizedBox(width: 12),
                  const Text('Сделать VIP', style: TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'block',
                child: Row(children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: (_blocked ? kTealDeep : const Color(0xFFC6403C)).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(_blocked ? Icons.lock_open_rounded : Icons.block_rounded,
                        size: 17, color: _blocked ? kTealDeep : const Color(0xFFC6403C)),
                  ),
                  const SizedBox(width: 12),
                  Text(_blocked ? 'Разблокировать' : 'Заблокировать',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF0E1519), Color(0xFF0B1013)] : const [Color(0xFFF4F7F8), Color(0xFFEDF2F2)],
          ),
        ),
        child: Column(children: [
          Expanded(
            child: ref.watch(firebaseMessagesProvider(widget.conversation.id)).when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Ошибка: $e')),
                  data: (msgs) => ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final idx = msgs.length - 1 - i;
                      final m = msgs[idx];
                      // Разделитель даты — как в WhatsApp: перед первым
                      // сообщением нового дня.
                      final prev = idx > 0 ? msgs[idx - 1] : null;
                      final newDay = m.createdAt != null &&
                          (prev?.createdAt == null || !_sameDay(prev!.createdAt!, m.createdAt!));
                      return Column(children: [
                        if (newDay) _dateChip(m.createdAt!, dark),
                        _bubble(m, dark),
                      ]);
                    },
                  ),
                ),
          ),
          if (_replyTo != null) _replyBar(dark),
          _composer(dark),
        ]),
      ),
    );
  }


  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  /// Плашка даты между сообщениями: «Сегодня» / «Вчера» / «23 июля 2026».
  Widget _dateChip(DateTime d, bool dark) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    final label = diff == 0
        ? 'Сегодня'
        : diff == 1
            ? 'Вчера'
            : (d.year == now.year ? dateRu(d) : '${dateRu(d)} ${d.year}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF223039) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.25 : 0.06), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: dark ? Colors.white70 : const Color(0xFF5C736C))),
      ),
    );
  }

  /// Кто из менеджеров отправил (мелким текстом под сообщением).
  String? _authorLabel(FsMessage m) {
    if (!m.isOutbound || m.isDeleted) return null;
    if (m.authorId == 'auto') return 'автоответ';
    final uid = m.authorId;
    if (uid == null || uid.isEmpty) {
      final wz = (m.authorName ?? '').trim();
      return wz.isEmpty ? null : wz;
    }
    // watch: подпись появится сама, когда список менеджеров подгрузится.
    final managers = ref.watch(managersProvider).value ?? const <Map<String, dynamic>>[];
    final me = ref.read(appConfigProvider).userId;
    var name = '';
    for (final u in managers) {
      if (u['id'] == uid) {
        name = ((u['name'] as String?) ?? '').trim();
        break;
      }
    }
    final who = name.isNotEmpty ? name : (uid == me ? 'вы' : 'менеджер');
    return m.isBroadcast ? '$who · рассылка' : who;
  }

  /// Запись о звонке — отдельная центрированная плашка, не пузырь.
  Widget _callNote(FsMessage m, bool dark) {
    final answered = m.callResult == 'answered';
    final color = answered ? const Color(0xFF23A35F) : const Color(0xFFC6403C);
    final who = (m.authorName ?? '').trim();
    final time = m.createdAt != null ? DateFormat('HH:mm').format(m.createdAt!) : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF223039) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(answered ? Iconsax.call_calling : Iconsax.call_slash, size: 15, color: color),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                '${answered ? 'Звонок' : 'Звонок без ответа'}'
                '${who.isEmpty ? '' : ' · $who'}'
                '${time.isEmpty ? '' : ' · $time'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _bubble(FsMessage m, bool dark) {
    if (m.type == 'call') return _callNote(m, dark);
    final out = m.isOutbound;
    final deleted = m.isDeleted;
    final hasMedia = !deleted && m.media != null && m.media!.isNotEmpty;
    final isImage = m.type == 'image' && hasMedia;
    final hasText = !deleted && m.text != null && m.text!.isNotEmpty;
    final body = deleted ? 'Сообщение удалено' : (hasText ? m.text! : (!hasMedia && m.type != 'text' ? '[${m.type}]' : ''));
    final time = m.createdAt != null ? DateFormat('HH:mm').format(m.createdAt!) : '';
    final textColor = out ? Colors.white : (dark ? const Color(0xFFE9EEF0) : const Color(0xFF0E1B22));
    final metaColor = out ? Colors.white.withValues(alpha: 0.85) : (dark ? Colors.white54 : Colors.black38);
    final author = _authorLabel(m);
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showMessageActions(m),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: EdgeInsets.fromLTRB(isImage ? 4 : 13, isImage ? 4 : 8, isImage ? 4 : 11, isImage ? 6 : 7),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
          decoration: BoxDecoration(
            gradient: out && !deleted ? brandGradient : null,
            color: deleted ? (dark ? const Color(0xFF222C33) : const Color(0xFFE9EEF0)) : (out ? null : (dark ? const Color(0xFF1B242B) : Colors.white)),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(out ? 18 : 6),
              bottomRight: Radius.circular(out ? 6 : 18),
            ),
            boxShadow: [BoxShadow(color: out && !deleted ? AppColors.brand.withValues(alpha: 0.22) : Colors.black.withValues(alpha: dark ? 0.25 : 0.05), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            if (!deleted && m.replyToText != null && m.replyToText!.isNotEmpty) _replyQuote(m.replyToText!, out, isImage),
            if (isImage) _mediaImage(m.media!),
            if (hasMedia && !isImage && m.type == 'audio') _FbVoicePlayer(url: m.media!, onGradient: out),
            if (hasMedia && !isImage && m.type != 'audio') _mediaCard(m, out),
            if (body.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: hasMedia ? 6 : 0, left: isImage ? 8 : 0, right: isImage ? 8 : 0),
                child: Text(body, style: TextStyle(color: deleted ? (dark ? Colors.white54 : Colors.black45) : textColor, fontSize: 15.5, height: 1.3, fontStyle: deleted ? FontStyle.italic : null)),
              ),
            Padding(
              padding: EdgeInsets.only(top: 2, right: isImage ? 8 : 0),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                // Кто ответил — мелким текстом рядом со временем.
                if (author != null) ...[
                  Text(author, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: metaColor)),
                  Text(' · ', style: TextStyle(fontSize: 10, color: metaColor)),
                ],
                if (m.isEdited && !deleted) ...[
                  Text('изм.', style: TextStyle(fontSize: 10, color: metaColor)),
                  const SizedBox(width: 4),
                ],
                Text(time, style: TextStyle(fontSize: 10.5, color: metaColor)),
                if (out && !deleted) ...[
                  const SizedBox(width: 3),
                  // «queued» — придержано лимитом темпа, уйдёт в ближайшие минуты.
                  if (m.status == 'queued')
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.schedule_rounded, size: 12, color: metaColor),
                      const SizedBox(width: 3),
                      Text('в очереди', style: TextStyle(fontSize: 10, color: metaColor)),
                    ])
                  else
                    Icon(
                      m.status == 'read' ? Icons.done_all : (m.status == 'delivered' ? Icons.done_all : Icons.check),
                      size: 13,
                      color: m.status == 'read' ? const Color(0xFFBEEFFF) : metaColor,
                    ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _replyQuote(String text, bool out, bool isImage) {
    final c = out ? Colors.white : AppColors.brand;
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 6, left: isImage ? 8 : 0, right: isImage ? 8 : 0, top: isImage ? 6 : 0),
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      decoration: BoxDecoration(
        color: (out ? Colors.white : AppColors.brand).withValues(alpha: 0.14),
        border: Border(left: BorderSide(color: c.withValues(alpha: 0.7), width: 3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: out ? Colors.white.withValues(alpha: 0.9) : (Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black54))),
    );
  }

  Widget _mediaImage(String url) {
    return GestureDetector(
      // Тап — открыть на весь экран с зумом.
      onTap: () => Navigator.of(context).push(PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => PhotoViewerPage(url: url),
        transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
      )),
      child: Hero(
        tag: url,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 258, maxHeight: 320, minWidth: 160, minHeight: 110),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              loadingBuilder: (c, w, p) => p == null
                  ? w
                  : Container(
                      width: 200, height: 150, color: Colors.black12, alignment: Alignment.center,
                      child: const CircularProgressIndicator(strokeWidth: 2)),
              errorBuilder: (_, _, _) => Container(
                  width: 200, height: 120, color: Colors.black12, alignment: Alignment.center,
                  child: const Icon(Icons.broken_image_outlined, color: Colors.grey)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _mediaCard(FsMessage m, bool out) {
    final fg = out ? Colors.white : AppColors.brand;
    final sub = out ? Colors.white70 : Colors.grey;
    final icon = switch (m.type) {
      'audio' => Icons.mic_rounded,
      'video' => Icons.play_circle_outline,
      _ => Icons.description_outlined,
    };
    final label = switch (m.type) {
      'audio' => 'Голосовое / аудио',
      'video' => 'Видео',
      _ => 'Файл',
    };
    return InkWell(
      onTap: m.media != null ? () => launchUrl(Uri.parse(m.media!), mode: LaunchMode.externalApplication) : null,
      child: SizedBox(
        width: 226,
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: (out ? Colors.white : AppColors.brand).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, color: fg, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: TextStyle(color: out ? Colors.white : const Color(0xFF10202A), fontWeight: FontWeight.w600, fontSize: 14)),
              Text('Открыть', style: TextStyle(fontSize: 11.5, color: sub)),
            ]),
          ),
          Icon(Icons.download_rounded, size: 20, color: fg),
        ]),
      ),
    );
  }

  Widget _replyBar(bool dark) {
    final m = _replyTo!;
    final preview = m.isDeleted ? 'Сообщение удалено' : (m.text?.isNotEmpty == true ? m.text! : '[${m.type}]');
    return Container(
      color: dark ? const Color(0xFF12191E) : Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        decoration: BoxDecoration(
          color: AppColors.brand.withValues(alpha: 0.10),
          border: const Border(left: BorderSide(color: AppColors.brand, width: 3)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          const Icon(Icons.reply_rounded, size: 16, color: AppColors.brand),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(m.isOutbound ? 'Ваше сообщение' : 'Ответ', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.brand)),
              Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: dark ? Colors.white70 : Colors.black54)),
            ]),
          ),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _replyTo = null)),
        ]),
      ),
    );
  }

  Widget _composer(bool dark) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        color: dark ? const Color(0xFF12191E) : Colors.white,
        child: _recording ? _recBar() : _inputBar(dark),
      ),
    );
  }

  Widget _recBar() {
    final m = (_recSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_recSeconds % 60).toString().padLeft(2, '0');
    return Row(children: [
      IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: _cancelRec),
      Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
      const SizedBox(width: 8),
      Text('$m:$s', style: const TextStyle(fontWeight: FontWeight.w600)),
      const Spacer(),
      const Text('Запись…', style: TextStyle(color: Colors.grey)),
      const SizedBox(width: 10),
      GestureDetector(
        onTap: _sending ? null : _stopRecAndSend,
        child: Container(
          width: 46, height: 46,
          decoration: const BoxDecoration(color: AppColors.brand, shape: BoxShape.circle),
          child: const Icon(Icons.send_rounded, color: Colors.white),
        ),
      ),
    ]);
  }

  void _openQuickReplies() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _QuickRepliesSheet(onPick: (text) {
        _input.text = text;
        _input.selection = TextSelection.fromPosition(TextPosition(offset: text.length));
        setState(() => _hasText = text.trim().isNotEmpty);
      }),
    );
  }

  Widget _inputBar(bool dark) {
    return Row(children: [
      IconButton(
        icon: const Icon(Icons.bolt_rounded, color: AppColors.brand),
        tooltip: 'Быстрые ответы',
        onPressed: _sending ? null : _openQuickReplies,
      ),
      IconButton(
        icon: const Icon(Icons.add_circle_outline_rounded, color: AppColors.brand),
        onPressed: _sending ? null : _pickAndSend,
      ),
      Expanded(
        child: TextField(
          controller: _input,
          minLines: 1, maxLines: 5,
          decoration: InputDecoration(
            hintText: 'Сообщение…',
            filled: true,
            fillColor: dark ? const Color(0xFF232E36) : const Color(0xFFEDF2F2),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
        ),
      ),
      const SizedBox(width: 8),
      GestureDetector(
        onTap: _sending ? null : (_hasText ? _send : _startRec),
        child: Container(
          width: 46, height: 46,
          decoration: const BoxDecoration(color: AppColors.brand, shape: BoxShape.circle),
          child: _sending
              ? const Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(_hasText ? Icons.send_rounded : Icons.mic_rounded, color: Colors.white),
        ),
      ),
    ]);
  }
}

/// Компактный проигрыватель голосового в firebase-режиме (just_audio).
class _FbVoicePlayer extends StatefulWidget {
  const _FbVoicePlayer({required this.url, required this.onGradient});
  final String url;
  final bool onGradient;

  @override
  State<_FbVoicePlayer> createState() => _FbVoicePlayerState();
}

class _FbVoicePlayerState extends State<_FbVoicePlayer> {
  final _player = AudioPlayer();
  bool _prepared = false;
  bool _loading = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!_prepared) {
      setState(() => _loading = true);
      try {
        await _player.setUrl(widget.url);
        _prepared = true;
      } catch (_) {
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось воспроизвести')));
        }
        return;
      }
      if (mounted) setState(() => _loading = false);
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) await _player.seek(Duration.zero);
      _player.play();
    }
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final og = widget.onGradient;
    final circleBg = og ? Colors.white : AppColors.brand;
    final circleFg = og ? AppColors.brand : Colors.white;
    final active = og ? Colors.white : AppColors.brand;
    final muted = og ? Colors.white.withValues(alpha: 0.35) : AppColors.brand.withValues(alpha: 0.3);
    final timeColor = og ? Colors.white.withValues(alpha: 0.85) : Colors.grey.shade600;

    return SizedBox(
      width: 210,
      child: Row(children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 38, height: 38,
            decoration: BoxDecoration(color: circleBg, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: _loading
                ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: circleFg))
                : Icon(_player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: circleFg, size: 22),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (context, snap) {
              final pos = snap.data ?? Duration.zero;
              final dur = _player.duration ?? Duration.zero;
              final progress = dur.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
              return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: progress, minHeight: 4, backgroundColor: muted, color: active),
                ),
                const SizedBox(height: 5),
                Text(_player.playing || pos > Duration.zero ? _fmt(pos) : _fmt(dur), style: TextStyle(fontSize: 11, color: timeColor)),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

/// Лист быстрых ответов: выбрать (вставится в поле), добавить, удалить.
class _QuickRepliesSheet extends ConsumerStatefulWidget {
  const _QuickRepliesSheet({required this.onPick});
  final void Function(String text) onPick;

  @override
  ConsumerState<_QuickRepliesSheet> createState() => _QuickRepliesSheetState();
}

class _QuickRepliesSheetState extends ConsumerState<_QuickRepliesSheet> {
  Future<void> _openEditor({QuickReply? existing}) async {
    final titleC = TextEditingController(text: existing?.title ?? '');
    final textC = TextEditingController(text: existing?.text ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(existing == null ? 'Новый шаблон' : 'Редактировать'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: titleC,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Заголовок', hintText: 'напр. Приветствие'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: textC,
            minLines: 2, maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Основной текст', hintText: 'Текст, который вставится в сообщение'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok == true && textC.text.trim().isNotEmpty) {
      final svc = ref.read(quickRepliesServiceProvider);
      final title = titleC.text.trim().isEmpty ? textC.text.trim() : titleC.text.trim();
      try {
        if (existing == null) {
          await svc.add(title: title, text: textC.text.trim());
        } else {
          await svc.update(existing.id, title: title, text: textC.text.trim());
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
    titleC.dispose();
    textC.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF12191E) : const Color(0xFFF2F5F7),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(children: [
            const SizedBox(height: 10),
            Container(width: 42, height: 5, decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(3))),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(children: [
                Icon(Icons.bolt_rounded, color: AppColors.brand),
                SizedBox(width: 8),
                Text('Быстрые ответы', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ]),
            ),
            Expanded(
              child: ref.watch(quickRepliesProvider).when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('Ошибка: $e')),
                    data: (items) {
                      if (items.isEmpty) {
                        return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Пока нет шаблонов.\nНажмите «Добавить».', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))));
                      }
                      return ListView.builder(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final q = items[i];
                          return Dismissible(
                            key: ValueKey(q.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              decoration: BoxDecoration(color: Colors.red.shade400, borderRadius: BorderRadius.circular(14)),
                              child: const Icon(Icons.delete_outline, color: Colors.white),
                            ),
                            onDismissed: (_) => ref.read(quickRepliesServiceProvider).delete(q.id),
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: Material(
                                color: dark ? const Color(0xFF1B242B) : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                clipBehavior: Clip.antiAlias,
                                child: ListTile(
                                title: Text(q.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                                subtitle: Text(q.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: dark ? Colors.white60 : Colors.black54)),
                                trailing: IconButton(icon: const Icon(Icons.edit_outlined, size: 19), onPressed: () => _openEditor(existing: q)),
                                onTap: () {
                                  widget.onPick(q.text);
                                  Navigator.of(context).pop();
                                },
                              ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: SizedBox(
                  height: 50,
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Добавить шаблон', style: TextStyle(fontWeight: FontWeight.w700)),
                    onPressed: () => _openEditor(),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Полноэкранный просмотр фото: пинч-зум, двойной тап, свайп вниз — закрыть.
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({super.key, required this.url});
  final String url;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> with SingleTickerProviderStateMixin {
  final _ctrl = TransformationController();
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _zoomAnim;
  double _dragY = 0; // смещение для свайпа вниз

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      if (_zoomAnim != null) _ctrl.value = _zoomAnim!.value;
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  bool get _zoomed => _ctrl.value.getMaxScaleOnAxis() > 1.05;

  /// Двойной тап: приблизить к точке касания / вернуть 1:1.
  void _toggleZoom(TapDownDetails d) {
    final target = _zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
          ..translateByDouble(-d.localPosition.dx * 1.5, -d.localPosition.dy * 1.5, 0, 1)
          ..scaleByDouble(2.5, 2.5, 1, 1));
    _zoomAnim = Matrix4Tween(begin: _ctrl.value, end: target).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
    );
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final opacity = (1 - (_dragY.abs() / 400)).clamp(0.35, 1.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: opacity),
      body: Stack(children: [
        // Свайп вниз закрывает (только когда не приближено).
        GestureDetector(
          onVerticalDragUpdate: _zoomed ? null : (d) => setState(() => _dragY += d.delta.dy),
          onVerticalDragEnd: _zoomed
              ? null
              : (d) {
                  if (_dragY.abs() > 110) {
                    Navigator.of(context).pop();
                  } else {
                    setState(() => _dragY = 0);
                  }
                },
          onDoubleTapDown: _toggleZoom,
          onDoubleTap: () {},
          child: Transform.translate(
            offset: Offset(0, _dragY),
            child: Center(
              child: Hero(
                tag: widget.url,
                child: InteractiveViewer(
                  transformationController: _ctrl,
                  minScale: 1,
                  maxScale: 5,
                  child: Image.network(
                    widget.url,
                    fit: BoxFit.contain,
                    loadingBuilder: (c, w, p) => p == null
                        ? w
                        : const SizedBox(
                            height: 120, width: 120,
                            child: Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))),
                    errorBuilder: (_, _, _) => const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('Не удалось загрузить фото', style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Кнопки поверх.
        Positioned(
          top: MediaQuery.of(context).padding.top + 6,
          left: 8,
          right: 8,
          child: Row(children: [
            _round(Icons.close_rounded, 'Закрыть', () => Navigator.of(context).pop()),
            const Spacer(),
            _round(Icons.open_in_new_rounded, 'Открыть в браузере',
                () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication)),
          ]),
        ),
      ]),
    );
  }

  Widget _round(IconData icon, String tip, VoidCallback onTap) => Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: IconButton(
          icon: Icon(icon, color: Colors.white, size: 22),
          tooltip: tip,
          onPressed: onTap,
        ),
      );
}
