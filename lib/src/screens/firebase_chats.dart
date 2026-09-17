import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iconsax/iconsax.dart';

import '../data/diag_service.dart';
import '../data/drafts_service.dart';
import '../data/firestore_chat_repository.dart';
import '../data/pending_match.dart';
import '../data/presence_service.dart';
import '../data/voice_controller.dart';
import '../data/quick_replies_service.dart';
import '../models/lead.dart';
import '../state/providers.dart';
import '../design/design.dart';
import '../theme/app_theme.dart';
import '../widgets/pdf_viewer_page.dart';
import 'lead_sheet.dart';
import 'massage_sheet.dart';
import 'soft_ui.dart';
import 'vip_client_sheet.dart';

const _chatsPageBg = Color(0xFFF2F2F7); // surface дизайн-системы

/// Список чатов — «мягкий» стиль: тил-шапка со скруглением, белый лист,
/// карточки с флаг-аватарами. VIP-чаты получают аватар assets/vip.png,
/// лиды — бейдж-молнию на флаге.
class FirebaseConversationsScreen extends ConsumerStatefulWidget {
  const FirebaseConversationsScreen({super.key});

  @override
  ConsumerState<FirebaseConversationsScreen> createState() =>
      _FirebaseConversationsScreenState();
}

/// Фильтр списка чатов. free/mine/foreign — логика четырёх менеджеров:
/// «свободен» (без ответственного) / «мои» / «чужие».
enum _ChatFilter { all, unread, mine, lead, massage, vip }

/// Вкладка транспорта: чаты Telegram и WhatsApp разделены.
/// Вкладки списка: два мессенджера и отдельные темы — «Звонок», «Обучение»
/// и «БАДы». Тематические чаты приходят из обоих мессенджеров и убираются
/// из вкладок Telegram/WhatsApp, чтобы не мешаться в потоке пациентов.
enum _Transport { telegram, whatsapp, training, supplements }

class _FirebaseConversationsScreenState
    extends ConsumerState<FirebaseConversationsScreen> {
  final _search = TextEditingController();
  String _query = '';
  _ChatFilter _filter = _ChatFilter.all;

  /// Активная вкладка транспорта (Telegram / WhatsApp).
  _Transport _transport = _Transport.telegram;

  // Тикер, пока где-то горит «отвечает …» — чтобы бейдж гас сам по себе,
  // даже если новых событий из Firestore не приходит.
  Timer? _typingTicker;

  // Тикер для цвета «клиент ждёт»: жёлтый/красный должны появляться сами по
  // себе, пока никто не написал ничего нового (Firestore в это время молчит).
  Timer? _slaTicker;

  /// Режим «забрать себе»: вместо открытия чата тап ставит галочку.
  /// Доступен только админу — менеджеры такой кнопки не видят.
  bool _pickMode = false;
  final Set<String> _picked = {};

  /// Найденное поиском ПО ВСЕЙ базе: список чатов держит только 500 свежих,
  /// а искать нужно и старые диалоги.
  List<FsConversation> _remote = const [];
  String _remoteFor = '';
  Timer? _searchDebounce;

  /// Результат поиска перебором («Искать по всей базе») и его состояние.
  /// Держим отдельно от быстрого поиска: перебор запускается только вручную.
  List<FsConversation> _deep = const [];
  String _deepFor = '';
  bool _deepBusy = false;

  void _searchRemote(String query) {
    _searchDebounce?.cancel();
    final q = query.trim();
    // Номер ищем от 4 цифр, имя — от 3 букв: «77» в запросе не должно тянуть
    // из базы всё подряд.
    final digits = q.replaceAll(RegExp(r'\D'), '');
    if (q.length < 3 && digits.length < 4) {
      if (_remote.isNotEmpty || _deep.isNotEmpty) {
        setState(() {
          _remote = const [];
          _deep = const [];
          _deepFor = '';
        });
      }
      return;
    }
    // Результат перебора относится к прежнему запросу — он больше не годится.
    if (_deepFor != q && _deep.isNotEmpty) {
      _deep = const [];
      _deepFor = '';
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final res = await ref
            .read(firestoreChatRepositoryProvider)
            .searchConversations(q);
        if (mounted && _query.trim() == q) {
          setState(() {
            _remote = res;
            _remoteFor = q;
          });
        }
      } catch (_) {
        /* поиск по базе не удался — остаётся поиск по загруженным */
      }
    });
  }

  /// Перебор всей коллекции: находит номер по последним цифрам и по куску
  /// из середины, чего быстрый поиск не умеет. Тысячи чтений, поэтому только
  /// по кнопке и только когда быстрый поиск ничего не дал.
  Future<void> _searchDeep() async {
    final q = _query.trim();
    if (q.isEmpty || _deepBusy) return;
    setState(() => _deepBusy = true);
    try {
      final res = await ref
          .read(firestoreChatRepositoryProvider)
          .deepSearchConversations(q);
      if (!mounted) return;
      setState(() {
        _deep = res;
        _deepFor = q;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Поиск не удался: $e')));
      }
    } finally {
      if (mounted) setState(() => _deepBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    // Один раз проверяем наличие vip.png: иначе каждый VIP-тайл при скролле
    // безуспешно грузит ассет заново (джанк из-за асинхронных исключений).
    if (vipAssetExists == null) {
      rootBundle
          .load('assets/vip.png')
          .then((_) {
            vipAssetExists = true;
            if (mounted) setState(() {});
          })
          .catchError((_) {
            vipAssetExists = false;
          });
    }
  }

  @override
  void dispose() {
    _typingTicker?.cancel();
    _slaTicker?.cancel();
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Запустить/остановить перерисовку раз в 5 сек, пока виден чей-то typing.
  void _ensureTypingTicker(bool anyTyping) {
    if (anyTyping && _typingTicker == null) {
      _typingTicker = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted) setState(() {});
      });
    } else if (!anyTyping && _typingTicker != null) {
      _typingTicker?.cancel();
      _typingTicker = null;
    }
  }

  /// Запустить/остановить перерисовку раз в 30 сек, пока хоть один чат ждёт
  /// ответа: 30 секунд достаточно для перехода между минутными порогами
  /// жёлтого/красного и не грузит слабые телефоны частыми перестройками.
  void _ensureSlaTicker(bool anyWaiting) {
    if (anyWaiting && _slaTicker == null) {
      _slaTicker = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (!anyWaiting && _slaTicker != null) {
      _slaTicker?.cancel();
      _slaTicker = null;
    }
  }

  /// Менеджеры для подписи «кто ответил последним». Обновляется в build,
  /// читается строками списка (в itemBuilder подписываться нельзя).
  List<Map<String, dynamic>> _managers = const [];

  /// Цвет вкладки: Telegram — тил, WhatsApp — зелёный, Звонок — синий,
  /// Обучение — оранжевый, БАДы — сиреневый. Где ты находишься, видно
  /// боковым зрением, без чтения подписей.
  static const _waAccent = Color(0xFF25D366);
  static const _waAccentDeep = Color(0xFF128C7E);
  static const _eduAccent = Color(0xFFFF9F0A);
  static const _eduAccentDeep = Color(0xFFC26A00);
  static const _badAccent = Color(0xFFAF52DE);
  static const _badAccentDeep = Color(0xFF7233A8);

  static Color _accentOf(_Transport t) => switch (t) {
    _Transport.telegram => kTeal,
    _Transport.whatsapp => _waAccent,
    _Transport.training => _eduAccent,
    _Transport.supplements => _badAccent,
  };
  static Color _accentDeepOf(_Transport t) => switch (t) {
    _Transport.telegram => kTealDeep,
    _Transport.whatsapp => _waAccentDeep,
    _Transport.training => _eduAccentDeep,
    _Transport.supplements => _badAccentDeep,
  };
  Color get _accent => _accentOf(_transport);
  Color get _accentDeep => _accentDeepOf(_transport);

  @override
  Widget build(BuildContext context) {
    final vipPhones = ref.watch(vipPhonesProvider);
    final leadPhones = ref.watch(leadPhonesProvider);
    final massagePhones = ref.watch(massagePhonesProvider);
    final leadsToday = ref.watch(leadsTodayCountProvider);
    // Черновики читаем ОДИН раз в build и передаём в строки параметром:
    // подписка внутри itemBuilder роняла плавность списка.
    final drafts = ref.watch(draftsProvider);
    _managers =
        ref.watch(managersProvider).value ?? const <Map<String, dynamic>>[];

    // Все чаты обоих транспортов (для счётчиков вкладок) и чаты активной
    // вкладки — список делится на Telegram и WhatsApp.
    //
    // Личные чаты владельца отсекаются здесь, ДО счётчиков вкладок: иначе
    // менеджер не видел бы чат в списке, но видел бы его в цифре
    // непрочитанных над вкладкой — и понимал, что переписка есть.
    final myUid = ref.watch(appConfigProvider).userId;
    final allItems =
        (ref.watch(firebaseConversationsProvider).value ??
                const <FsConversation>[])
            .where((c) => c.privateOwnerUid == null || c.privateOwnerUid == myUid)
            .toList();
    final items = allItems.where(_inTransport).toList();

    // Статистика дня — в шапке (стеклянные карточки на тил-фоне).
    final todayChats = items.where((c) => _isToday(c.lastMessageAt)).toList();
    final answered = todayChats.where((c) => c.unreadCount == 0).length;

    final conv = ref.watch(firebaseConversationsProvider);
    // Пока кто-то печатает — тикер, чтобы бейдж «отвечает …» гас сам.
    _ensureTypingTicker(
      items.any((c) =>
          c.typingByOther(ref.read(appConfigProvider).userId) ||
          c.viewerOther(ref.read(appConfigProvider).userId) != null),
    );
    // Пока хоть один клиент ждёт ответа — тикер для жёлтого/красного цвета.
    _ensureSlaTicker(items.any((c) => c.waitingMinutes() != null));

    // Сворачивающаяся шапка: при прокрутке большая часть уходит, сверху
    // остаётся закреплённая мини-полоска («Чаты» + кто в сети). Никакого
    // floating/snap — на части Android (Samsung A5x) их анимация
    // зацикливалась: шапка дёргалась сама, тапы промахивались, клавиатура
    // закрывалась. Pinned-шапка не анимирует появление — дёргаться нечему.
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;
    final topPad = MediaQuery.of(context).padding.top;
    const miniHeaderH = 46.0;
    // Ряд вкладок Telegram/WhatsApp занимает высоту 38 + отступ 12 —
    // без этой добавки развёрнутая шапка не влезает (overflow).
    const transportTabsH = 50.0;
    final header = SliverAppBar(
      automaticallyImplyLeading: false,
      primary: false,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      toolbarHeight: 0,
      pinned: true,
      collapsedHeight: topPad + miniHeaderH,
      expandedHeight: topPad + 292 + (kShowWhatsAppChats ? transportTabsH : 0),
      // Шапка и мини-полоска собираются ОДИН раз за build экрана и
      // переиспользуются внутри LayoutBuilder: одинаковый экземпляр виджета
      // Flutter не пересобирает, иначе вся шапка (градиент, поиск, вкладки,
      // чипы) перестраивалась на каждый кадр прокрутки и список подлагивал.
      // Смена мессенджера перекрашивает шапку плавно. Анимируем ТОЛЬКО её
      // поддерево: строки списка при переключении и так меняются целиком.
      flexibleSpace: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: _accent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        builder: (context, top, _) => TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: _accentDeep),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          builder: (context, bottom, _) {
            final accent = top ?? _accent;
            final accentDeep = bottom ?? _accentDeep;
            final big = FlexibleSpaceBar(
              collapseMode: CollapseMode.pin,
              background: SoftHeader(
                color: accent,
                colorDeep: accentDeep,
                title: 'Чаты',
                dateLabel: weekdayDateRu(DateTime.now()),
                actions: [
                  if (_isAdmin) ...[
                    SoftHeaderButton(
                      icon: _pickMode ? Iconsax.close_square : Iconsax.task_square,
                      tooltip: _pickMode ? 'Выйти из выбора' : 'Забрать чаты себе',
                      active: _pickMode,
                      onTap: () => setState(() {
                        _pickMode = !_pickMode;
                        _picked.clear();
                      }),
                    ),
                    const SizedBox(width: 8),
                  ],
                  const _FbOnlineBadge(),
                ],
                strip: Column(
                  children: [
                    _searchBar(),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        HeaderStat(
                          value: '$leadsToday',
                          label: 'лидов сегодня',
                          onTap: _showTodayLeads,
                        ),
                        const SizedBox(width: 9),
                        HeaderStat(
                          value: todayChats.isEmpty
                              ? '—'
                              : '$answered/${todayChats.length}',
                          label: 'отвечено чатов',
                        ),
                      ],
                    ),
                    if (kShowWhatsAppChats) ...[
                      const SizedBox(height: 12),
                      _transportTabs(allItems),
                    ],
                    const SizedBox(height: 12),
                    _filterChips(
                      items,
                      vipPhones,
                      leadPhones,
                      massagePhones,
                      accentDeep,
                    ),
                  ],
                ),
              ),
            );
            final mini = Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accent, accentDeep],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              padding: EdgeInsets.fromLTRB(20, topPad, 12, 0),
              child: Row(
                children: [
                  Text(
                    kShowWhatsAppChats
                        ? switch (_transport) {
                            _Transport.telegram => 'Чаты · Telegram',
                            _Transport.whatsapp => 'Чаты · WhatsApp',
                            _Transport.training => 'Чаты · Обучение',
                            _Transport.supplements => 'Чаты · БАДы',
                          }
                        : 'Чаты',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const Spacer(),
                  const _FbOnlineBadge(),
                ],
              ),
            );
            return LayoutBuilder(
              builder: (context, cons) {
                final collapsed = cons.maxHeight <= topPad + miniHeaderH + 4;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    big,
                    // Мини-полоска: остаётся закреплённой, когда большая шапка ушла.
                    IgnorePointer(
                      ignoring: !collapsed,
                      child: AnimatedOpacity(
                        opacity: collapsed ? 1 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: mini,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );

    return Scaffold(
      backgroundColor: _chatsPageBg,
      // Панель действий появляется только в режиме выбора и висит над
      // списком: кнопка «Забрать» должна быть под большим пальцем, а не
      // где-то в шапке, куда придётся тянуться после набора десятка чатов.
      bottomNavigationBar: _pickMode ? _pickBar() : null,
      body: CustomScrollView(
        // Платформенные физики: iOS — привычная «пружина», Android — clamping
        // (без отскока у нуля, который раскачивал floating-шапку).
        physics: isIOS
            ? const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              )
            : const AlwaysScrollableScrollPhysics(),
        slivers: [
          header,
          ...conv.when(
            // Заготовки строк вместо крутилки: видно, что список уже рисуется.
            loading: () => [
              const SliverFillRemaining(child: SkeletonList(count: 8)),
            ],
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
            data: (_) {
              // Берём allItems, а не список из провайдера: в нём уже отсеяны
              // личные чаты владельца. Раньше здесь стоял сырой список — и
              // забранная переписка, пропав из счётчиков, всё равно рисовалась
              // в самом списке у остальных менеджеров.
              final items = allItems.where(_inTransport).toList();
              // Поиск: по имени, номеру (цифрам) и тексту последнего сообщения.
              final q = _query.trim().toLowerCase();
              final qDigits = q.replaceAll(RegExp(r'\D'), '');
              // Номер набирают как привыкли: «8 989…», «+7 989…» или без кода
              // страны. Ищем по всем написаниям сразу.
              final qPhones = FirestoreChatRepository.phoneSearchVariants(
                qDigits,
              );
              // Поиск идёт ПО ВСЕМ вкладкам и мимо фильтра. Менеджер не знает,
              // в каком разделе лежит чат (Telegram / WhatsApp / Звонок /
              // Обучение / БАДы) — и не должен угадывать, чтобы найти номер.
              final pool = q.isEmpty ? items : allItems;
              // Заблокированные скрыты из списка, но находятся поиском.
              var filtered = q.isEmpty
                  ? pool
                        .where((c) => !c.blocked)
                        .where(
                          (c) =>
                              _matches(c, vipPhones, leadPhones, massagePhones),
                        )
                        .toList()
                  : pool.where((c) {
                      final digits = (c.phone ?? c.id).replaceAll(
                        RegExp(r'\D'),
                        '',
                      );
                      // Цифры имени тоже: у телеграм-чата с известным номером
                      // имя — это «+7989…», а поле phone бывает пустым.
                      final nameDigits = c.name.replaceAll(RegExp(r'\D'), '');
                      return c.name.toLowerCase().contains(q) ||
                          (qDigits.isNotEmpty &&
                              qPhones.any(
                                (p) =>
                                    digits.contains(p) ||
                                    nameDigits.contains(p),
                              )) ||
                          (qDigits.isNotEmpty && digits.contains(qDigits)) ||
                          (c.preview ?? '').toLowerCase().contains(q);
                    }).toList();
              // Добавляем найденное по всей базе: старый чат (писал неделю
              // назад) в загруженные 500 не попадает, но найтись должен.
              // Сюда же попадает результат перебора («Искать по всей базе»).
              if (q.isNotEmpty) {
                final extra = <FsConversation>[
                  if (_remoteFor == _query.trim()) ..._remote,
                  if (_deepFor == _query.trim()) ..._deep,
                ];
                final have = filtered.map((c) => c.id).toSet();
                filtered = [
                  ...filtered,
                  // Личные чаты владельца отсекаются и здесь. Поиск идёт по
                  // ВСЕЙ базе мимо основного списка — без этой проверки
                  // менеджер, набрав номер, находил бы забранную переписку,
                  // хотя в списке её нет.
                  ...extra.where(
                    (c) =>
                        have.add(c.id) &&
                        (c.privateOwnerUid == null ||
                            c.privateOwnerUid == myUid),
                  ),
                ];
              }
              if (filtered.isEmpty) {
                // Во время поиска открыта клавиатура, и под шапкой остаётся
                // полоска в несколько десятков пикселей. Высокий блок по
                // центру в неё не помещался: из него был виден только верх
                // бледного квадрата под иконку — тот самый «белый квадрат».
                // Поэтому у поиска своя компактная плашка, прижатая к шапке.
                if (q.isNotEmpty) {
                  return [SliverToBoxAdapter(child: _searchEmpty())];
                }
                return [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _filter != _ChatFilter.all
                        ? _msg(
                            Iconsax.filter,
                            'Здесь пусто',
                            'В этой вкладке сейчас нет чатов',
                          )
                        : switch (_transport) {
                            _Transport.whatsapp => _msg(
                              Icons.chat_rounded,
                              'Нет чатов WhatsApp',
                              'Появятся, когда канал Wazzup будет подключён и оплачен',
                            ),
                            _Transport.training => _msg(
                              Icons.school_rounded,
                              'Пока нет обращений по обучению',
                              'Чат попадёт сюда, как только клиент напишет про обучение',
                            ),
                            _Transport.supplements => _msg(
                              Icons.medication_rounded,
                              'Пока нет обращений по БАДам',
                              'Чат попадёт сюда, как только клиент напишет про БАДы',
                            ),
                            _Transport.telegram => _msg(
                              Iconsax.message,
                              'Пока нет чатов',
                              'Входящие появятся здесь',
                            ),
                          },
                  ),
                ];
              }
              return [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    15,
                    14,
                    15,
                    24 + MediaQuery.paddingOf(context).bottom,
                  ),
                  sliver: SliverList.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final c = filtered[i];
                      final digits = (c.phone ?? '').replaceAll(
                        RegExp(r'\D'),
                        '',
                      );
                      return _tile(
                        context,
                        c,
                        isVip: vipPhones.contains(digits),
                        isLead: leadPhones.contains(digits),
                        isMassage: massagePhones.contains(digits),
                        draft: drafts[c.id],
                      );
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

  /// Нижняя панель режима выбора: сколько отмечено и что с ними сделать.
  Widget _pickBar() {
    final n = _picked.length;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE6E6EA))),
          boxShadow: [
            BoxShadow(color: Color(0x14000000), blurRadius: 14, offset: Offset(0, -3)),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                n == 0 ? 'Отметьте чаты' : 'Отмечено: $n',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: n == 0 ? kSub : kInk,
                ),
              ),
            ),
            if (n > 0) ...[
              TextButton(
                onPressed: _releasePicked,
                child: const Text('Вернуть всем'),
              ),
              const SizedBox(width: 6),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _accentDeep),
                onPressed: _takePicked,
                child: const Text('Забрать себе'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Забирать чаты себе может только владелец.
  bool get _isAdmin {
    final role = ref.read(appConfigProvider).role;
    return role == 'admin' || role == 'administrator';
  }

  /// Забрать отмеченные чаты себе: у остальных менеджеров они пропадут из
  /// списка и по ним перестанут приходить пуши.
  Future<void> _takePicked() async {
    final ids = _picked.toList();
    if (ids.isEmpty) return;
    final uid = ref.read(appConfigProvider).userId;
    if (uid == null) return;
    try {
      await ref.read(firestoreChatRepositoryProvider).setPrivateOwner(ids, uid);
      if (!mounted) return;
      setState(() {
        _pickMode = false;
        _picked.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Забрано себе: ${ids.length}')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось забрать: $e')));
      }
    }
  }

  /// Вернуть отмеченные чаты в общий список.
  Future<void> _releasePicked() async {
    final ids = _picked.toList();
    if (ids.isEmpty) return;
    try {
      await ref.read(firestoreChatRepositoryProvider).setPrivateOwner(ids, null);
      if (!mounted) return;
      setState(() {
        _pickMode = false;
        _picked.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Возвращено в общий список: ${ids.length}')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось вернуть: $e')));
      }
    }
  }

  /// Чат относится к активной вкладке транспорта.
  bool _inTransport(FsConversation c) {
    if (!kShowWhatsAppChats) return c.isTelegram;
    return _inTab(c, _transport);
  }

  /// Чат попадает во вкладку. Тематические вкладки («Обучение», «БАДы»)
  /// собирают чаты из обоих мессенджеров и забирают их из вкладок Telegram и
  /// WhatsApp, чтобы пациенты, ученики и покупатели БАДов не смешивались.
  /// Раздела «Звонок» больше нет (решение владельца 2026-09-06): просьба
  /// перезвонить — обычный пациентский чат в своём мессенджере.
  static bool _inTab(FsConversation c, _Transport tab) {
    if (tab == _Transport.training) return c.isTraining;
    if (tab == _Transport.supplements) return c.isSupplements;
    if (c.hasOwnTab) return false;
    return tab == _Transport.telegram ? c.isTelegram : !c.isTelegram;
  }

  /// Переключатель вкладок со счётчиками непрочитанных.
  ///
  /// Только иконки, без подписей: вкладок стало пять, и на узких экранах
  /// подписи ужимались до «Telegr…» / «Обуче…» — читалось хуже, чем понятная
  /// иконка. Название открытого раздела и так написано в шапке над вкладками,
  /// а долгое нажатие показывает подсказку.
  Widget _transportTabs(List<FsConversation> all) {
    final tabs = <(_Transport, String, IconData)>[
      (_Transport.telegram, 'Telegram', Icons.telegram),
      (_Transport.whatsapp, 'WhatsApp', Icons.chat_rounded),
      (_Transport.training, 'Обучение', Icons.school_rounded),
      (_Transport.supplements, 'БАДы', Icons.medication_rounded),
    ];
    return Row(
      children: [
        for (final (t, label, icon) in tabs) ...[
          Expanded(
            child: Builder(
              builder: (context) {
                final sel = _transport == t;
                // Цвет вкладки — по её теме, а не по открытой сейчас: WhatsApp
                // зелёный, даже когда смотришь Telegram.
                final tabColor = _accentDeepOf(t);
                final badgeColor = _accentOf(t);
                final list = all.where((c) => !c.blocked && _inTab(c, t));
                final unread = list
                    .where((c) => c.unreadCount > 0 || c.manualUnread)
                    .length;
                return Material(
                  color: sel
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _transport = t),
                    child: Tooltip(
                      message: label,
                      child: Container(
                        height: 38,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              icon,
                              size: 20,
                              color: sel ? tabColor : Colors.white,
                            ),
                            if (unread > 0) ...[
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: sel
                                      ? badgeColor
                                      : Colors.white.withValues(alpha: 0.28),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Text(
                                  '$unread',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (t != tabs.last.$1) const SizedBox(width: 6),
        ],
      ],
    );
  }

  /// Подходит ли чат под выбранную вкладку.
  bool _matches(
    FsConversation c,
    Set<String> vip,
    Set<String> lead,
    Set<String> mass,
  ) {
    // Только настоящий номер: id телеграм-чата телефоном не является.
    final digits = (c.phone ?? '').replaceAll(RegExp(r'\D'), '');
    return switch (_filter) {
      _ChatFilter.all => true,
      // Непрочитанные: и автоматический счётчик, и ручная отметка.
      _ChatFilter.unread => c.unreadCount > 0 || c.manualUnread,
      // Забранные мной: чтобы найти их и вернуть в общий список.
      _ChatFilter.mine => c.privateOwnerUid != null &&
          c.privateOwnerUid == ref.read(appConfigProvider).userId,
      _ChatFilter.lead => lead.contains(digits),
      _ChatFilter.massage => mass.contains(digits),
      _ChatFilter.vip => vip.contains(digits),
    };
  }

  /// Сколько чатов попадает во вкладку (для счётчика).
  int _countFor(
    _ChatFilter f,
    List<FsConversation> items,
    Set<String> vip,
    Set<String> lead,
    Set<String> mass,
  ) {
    final old = _filter;
    _filter = f;
    final n = items
        .where((c) => !c.blocked && _matches(c, vip, lead, mass))
        .length;
    _filter = old;
    return n;
  }

  /// Вкладки-фильтры со счётчиками (в шапке, горизонтальный скролл).
  Widget _filterChips(
    List<FsConversation> items,
    Set<String> vip,
    Set<String> lead,
    Set<String> mass,
    Color accentDeep,
  ) {
    // «Мои» — только владельцу: у менеджеров забранных чатов не бывает,
    // пустая вкладка их только запутает.
    final tabs = <(_ChatFilter, String)>[
      (_ChatFilter.all, 'Все'),
      (_ChatFilter.unread, 'Непрочитанные'),
      if (_isAdmin) (_ChatFilter.mine, 'Мои'),
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                        color: sel ? accentDeep : Colors.white,
                      ),
                    ),
                    if (n > 0) ...[
                      const SizedBox(width: 5),
                      Text(
                        '$n',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: sel
                              ? accentDeep.withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ],
                ),
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  displayName(c.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: kInk,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Iconsax.copy, color: kTealDeep),
              title: const Text(
                'Скопировать номер',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              onTap: () => Navigator.pop(sheet, 'copy'),
            ),
            ListTile(
              leading: Icon(
                unread ? Iconsax.tick_circle : Iconsax.message_notif,
                color: kTealDeep,
              ),
              title: Text(
                unread ? 'Отметить прочитанным' : 'Отметить непрочитанным',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              onTap: () => Navigator.pop(sheet, unread ? 'read' : 'unread'),
            ),
            ListTile(
              leading: Icon(
                c.blocked ? Icons.lock_open_rounded : Icons.block_rounded,
                color: c.blocked ? kTealDeep : const Color(0xFFC6403C),
              ),
              title: Text(
                c.blocked ? 'Разблокировать' : 'Заблокировать',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              onTap: () => Navigator.pop(sheet, 'block'),
            ),
            const SizedBox(height: 8),
          ],
        ),
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
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
        onChanged: (v) {
          setState(() => _query = v);
          _searchRemote(v);
        },
        textInputAction: TextInputAction.search,
        // Кнопка «Поиск» на клавиатуре — сразу перебор по всей базе: её
        // жмут именно тогда, когда быстрый поиск ничего не показал.
        onSubmitted: (_) => _searchDeep(),
        cursorColor: Colors.white,
        style: const TextStyle(fontSize: 14.5, color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Поиск: имя или номер',
          hintStyle: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.75),
          ),
          filled: false,
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 13),
          prefixIcon: Icon(
            Iconsax.search_normal_1,
            size: 19,
            color: Colors.white.withValues(alpha: 0.85),
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: Icon(
                    Iconsax.close_circle,
                    size: 19,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                  tooltip: 'Очистить',
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                    _searchRemote('');
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
    // Список менеджеров берём из поля: ref.watch здесь нельзя — метод
    // вызывается из itemBuilder (см. комментарий у _tile).
    for (final u in _managers) {
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

  /// Открывает список лидов с возможностью листать по дням (не только
  /// сегодня). Нажатие на строку открывает карточку лида на правку.
  Future<void> _showTodayLeads() async {
    final picked = await showModalBottomSheet<Lead>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _LeadsDaySheet(),
    );
    if (picked != null && mounted) {
      await LeadSheet.show(context, existing: picked);
    }
  }

  /// Строка списка чатов.
  ///
  /// ВАЖНО: здесь нельзя обращаться к провайдерам через ref.watch — метод
  /// вызывается из itemBuilder (во время раскладки, а не сборки), и подписка
  /// оттуда заставляет список пересобираться постоянно: список начинает
  /// заметно тормозить. Всё, что нужно, приходит параметрами.
  Widget _tile(
    BuildContext context,
    FsConversation c, {
    required bool isVip,
    required bool isLead,
    bool isMassage = false,
    String? draft,
  }) {
    final unread = c.unreadCount > 0 || c.manualUnread;
    final time = _listTime(c.lastMessageAt);
    final lastAuthor = _lastAuthor(c);
    // Печатает ли сейчас другой менеджер (свежий heartbeat). Если не
    // печатает, но просто НАХОДИТСЯ в чате — тоже показываем: решение
    // «беру этот чат» принимается при открытии, раньше первой буквы.
    final myUidRow = ref.read(appConfigProvider).userId;
    final typingBy =
        c.typingByOther(myUidRow) ? (c.typingName ?? 'менеджер') : null;
    final viewingBy = typingBy == null
        ? (() {
            final v = c.viewerOther(myUidRow);
            if (v == null) return null;
            return v.name.isEmpty ? 'менеджер' : v.name;
          })()
        : null;
    // Сколько клиент ждёт ответа: 5–10 мин — жёлтый, 10+ — красный.
    // Менеджеров надо подталкивать раньше, чем клиент начнёт нервничать.
    final waitMin = c.waitingMinutes();
    final slaColor = waitMin == null
        ? null
        : waitMin >= 10
        ? const Color(0xFFE5484D)
        : waitMin >= 5
        ? const Color(0xFFF5A623)
        : null;
    // Клиент ждёт долго — красится вся карточка целиком (тёплый фон + рамка
    // в цвет), а не только колечко на аватаре: так сигнал ловится сразу при
    // беглом скролле списка, ещё до того, как взгляд дойдёт до аватара.
    // Чат, который я забрал себе: менеджеры его не видят, а мне нужно
    // отличать такие от общих — иначе вернуть их потом можно только на
    // память. Тонируем карточку и ставим метку (см. ниже).
    final isMine = c.privateOwnerUid != null &&
        c.privateOwnerUid == ref.read(appConfigProvider).userId;
    final cardTint = isMine
        ? const Color(0xFFF3F0FF)
        : slaColor == null
            ? Colors.white
            : Color.alphaBlend(slaColor.withValues(alpha: 0.10), Colors.white);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: cardTint,
        borderRadius: BorderRadius.circular(22),
        border: isMine
            ? Border.all(color: const Color(0xFF5E5CE6).withValues(alpha: 0.45), width: 1.4)
            : slaColor == null
                ? null
                : Border.all(color: slaColor.withValues(alpha: 0.55), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: (slaColor ?? Colors.black).withValues(
              alpha: slaColor == null ? 0.05 : 0.16,
            ),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          // В режиме выбора тап ставит галочку, а не открывает переписку:
          // иначе набрать десяток чатов было бы невозможно — каждый тап
          // уводил бы с экрана.
          onTap: _pickMode
              ? () => setState(() {
                    if (!_picked.remove(c.id)) _picked.add(c.id);
                  })
              : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FirebaseChatScreen(conversation: c),
                    ),
                  ),
          onLongPress: _pickMode ? null : () => _chatActions(c, unread),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 13, 14, 13),
            child: Row(
              children: [
                if (_pickMode) ...[
                  Icon(
                    _picked.contains(c.id)
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 24,
                    color: _picked.contains(c.id) ? _accentDeep : kSub,
                  ),
                  const SizedBox(width: 10),
                ],
                _ChatAvatar(
                  phone: c.phone ?? c.id,
                  isVip: isVip,
                  isLead: isLead,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // Без FittedBox: он подгонял ширину под глифы (эмодзи,
                          // казахские буквы), и время в списке «гуляло» по строкам
                          // вместо ровной колонки справа.
                          Expanded(
                            child: Text(
                              displayName(c.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                color: kInk,
                                letterSpacing: -0.2,
                                height: 1.1,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Фиксированная колонка справа — время всех строк в одну
                          // линию (моноширинные цифры + правое выравнивание).
                          // Ждёт долго — время красное/жёлтое, тот же сигнал, что
                          // и на аватаре, второй раз ловится боковым зрением.
                          SizedBox(
                            width: 52,
                            child: Text(
                              time,
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: unread || slaColor != null
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color:
                                    slaColor ?? (unread ? _accentDeep : kSub),
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          // Метка статуса стоит ЗДЕСЬ, а не рядом с именем:
                          // длинные («СОХРАНИ ЛИДА», «ЖДЁТ ЗАПИСИ») съедали
                          // ширину верхней строки, и номер телефона — по
                          // которому менеджер узнаёт клиента — обрезался
                          // многоточием. Номер важнее превью переписки,
                          // поэтому потеснили превью.
                          if (isMine)
                            const _TagChip(
                              label: 'У МЕНЯ',
                              bg: Color(0xFFE7E5FF),
                              fg: Color(0xFF4B48C8),
                              gapLeft: 0,
                              gapRight: 6,
                            ),
                          if (c.blocked)
                            const _TagChip(
                              label: 'БЛОК',
                              bg: Color(0xFFEDEDEF),
                              fg: Color(0xFF74747C),
                              gapLeft: 0,
                              gapRight: 6,
                            )
                          else if (isVip)
                            const _TagChip(
                              label: 'VIP',
                              bg: Color(0xFFFDF3D7),
                              fg: Color(0xFF9A7208),
                              gapLeft: 0,
                              gapRight: 6,
                            )
                          else if (isLead)
                            const _TagChip(
                              label: 'ЛИД',
                              bg: Color(0xFFDFF4EF),
                              fg: kTealDeep,
                              gapLeft: 0,
                              gapRight: 6,
                            )
                          ,
                          Expanded(
                            // «отвечает Имя…» — другой менеджер уже печатает ответ.
                            // Главный сигнал против двойных ответов.
                            // Ниже приоритетом — свой недописанный черновик.
                            child: typingBy == null && draft != null
                                ? Row(
                                    children: [
                                      const Text(
                                        'Черновик: ',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: Color(0xFFC26A00),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          draft,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            color: kSub,
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : typingBy != null || viewingBy != null
                                ? Text(
                                    typingBy != null
                                        ? 'отвечает $typingBy…'
                                        : 'в чате $viewingBy',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: _accentDeep,
                                      fontWeight: FontWeight.w800,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  )
                                : Row(
                                    children: [
                                      // Кто ответил последним — как «Вы:» в WhatsApp.
                                      if (lastAuthor != null)
                                        Text(
                                          '$lastAuthor: ',
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            color: _accentDeep,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      Expanded(
                                        child: Text(
                                          c.preview ?? '',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            color: kSub,
                                            fontWeight: unread
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                          if (unread)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: EdgeInsets.symmetric(
                                horizontal: c.unreadCount > 0 ? 7 : 6,
                                vertical: c.unreadCount > 0 ? 2 : 6,
                              ),
                              decoration: BoxDecoration(
                                color: _accent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: c.unreadCount > 0
                                  ? Text(
                                      '${c.unreadCount}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    )
                                  : const SizedBox.shrink(), // ручная отметка — просто точка
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// «Ничего не найдено» для поиска: низкая плашка сразу под шапкой.
  ///
  /// Высокая заглушка по центру здесь не годится — с открытой клавиатурой
  /// под шапкой остаётся 50–80 px, и от неё было видно только скруглённый
  /// угол подложки под иконку.
  Widget _searchEmpty() {
    final deepDone = _deepFor == _query.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 16, 15, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(Iconsax.search_normal, size: 19, color: _accentDeep),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Ничего не найдено',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: kInk,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      deepDone
                          ? 'Прошли по всей базе — такого чата нет. Проверьте номер или имя.'
                          : 'Поиск идёт по всем разделам. Номер можно писать как угодно: +7…, 8… или без кода.',
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.25,
                        color: kSub,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Быстрый поиск находит по НАЧАЛУ номера и имени. Если набраны
          // последние цифры или кусок из середины — помогает только перебор
          // всей базы, а он платный (тысячи чтений), поэтому по кнопке.
          if (!deepDone) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _accentDeep,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: _deepBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Iconsax.search_normal_1, size: 17),
                label: Text(
                  _deepBusy ? 'Ищем по всей базе…' : 'Искать по всей базе',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: _deepBusy ? null : _searchDeep,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _msg(IconData i, String t, String s, {VoidCallback? onRetry}) =>
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(i, size: 34, color: _accentDeep),
              ),
              const SizedBox(height: 16),
              Text(
                t,
                style: const TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700,
                  color: kInk,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                s,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: kSub),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 18),
                SizedBox(
                  width: 190,
                  height: 46,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _accentDeep,
                      minimumSize: const Size(190, 46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text(
                      'Подключиться заново',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onPressed: onRetry,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
}

/// Список лидов за день с возможностью листать соседние дни — открывается
/// нажатием на карточку «N лидов сегодня» в шапке. По умолчанию — сегодня,
/// стрелками или тапом по дате можно посмотреть любой прошедший день.
class _LeadsDaySheet extends ConsumerStatefulWidget {
  const _LeadsDaySheet();

  @override
  ConsumerState<_LeadsDaySheet> createState() => _LeadsDaySheetState();
}

class _LeadsDaySheetState extends ConsumerState<_LeadsDaySheet> {
  DateTime _day = DateTime.now();

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2025, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _day = picked);
  }

  void _shiftDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(DateTime.now())) return;
    setState(() => _day = next);
  }

  /// Цвет аватара-инициала — по хешу имени, чтобы соседние лиды визуально
  /// не сливались в одинаковые зелёные квадраты.
  static const _palette = [
    Color(0xFF0E8F82),
    Color(0xFF4C6FFF),
    Color(0xFFB65C00),
    Color(0xFFC0447B),
    Color(0xFF5A4FCF),
    Color(0xFF1B8A5A),
  ];
  static Color _colorFor(String seed) =>
      _palette[seed.isEmpty ? 0 : seed.codeUnitAt(0) % _palette.length];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final leads =
        (ref.watch(leadsListProvider).value ?? const <Lead>[])
            .where(
              (l) =>
                  !l.archived &&
                  l.createdAt != null &&
                  _sameDay(l.createdAt!, _day),
            )
            .toList()
          ..sort(
            (a, b) => (b.createdAt ?? DateTime(0)).compareTo(
              a.createdAt ?? DateTime(0),
            ),
          );
    final managers =
        ref.watch(managersProvider).value ?? const <Map<String, dynamic>>[];
    String author(String? uid) {
      if (uid == null || uid.isEmpty) return '';
      for (final m in managers) {
        if (m['id'] == uid) {
          return ((m['name'] as String?) ?? '').trim().split(' ').first;
        }
      }
      return '';
    }

    final today = _sameDay(_day, DateTime.now());
    // Без потолка по высоте лист растягивался на весь экран, как только
    // лидов набиралось много (Flexible внутри Column ничем не ограничен,
    // если модалка сама не задала максимум). Ограничиваем — список ниже
    // прокручивается сам, а сверху остаётся видна шапка «Чаты» позади.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: t.card,
          shape: squircleTop(AppRadius.xl),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 5,
                decoration: ShapeDecoration(
                  color: t.separator,
                  shape: squircle(3),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 10, 18, 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => _shiftDay(-1),
                      icon: Icon(
                        Icons.chevron_left_rounded,
                        size: 26,
                        color: t.textSecondary,
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _pickDay,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            children: [
                              Text(
                                today ? 'Лиды сегодня' : 'Лиды',
                                style: TextStyle(
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w800,
                                  color: t.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                today
                                    ? 'нажмите на дату, чтобы посмотреть другой день'
                                    : weekdayDateRu(_day),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: t.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: today ? null : () => _shiftDay(1),
                      icon: Icon(
                        Icons.chevron_right_rounded,
                        size: 26,
                        color: today ? t.textTertiary : t.textSecondary,
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.only(left: 2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: ShapeDecoration(
                        color: kTeal.withValues(alpha: 0.12),
                        shape: squircle(10),
                      ),
                      child: Text(
                        '${leads.length}',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: kTealDeep,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, thickness: 0.6, color: t.separator),
              if (leads.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 30, 18, 34),
                  child: Column(
                    children: [
                      Icon(Iconsax.flash_1, size: 28, color: t.textTertiary),
                      const SizedBox(height: 10),
                      Text(
                        today
                            ? 'Сегодня лидов ещё не создавали'
                            : 'В этот день лидов не было',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: t.textSecondary,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(0, 6, 0, 14),
                    itemCount: leads.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 0.5,
                      thickness: 0.5,
                      color: t.separator,
                      indent: 70,
                    ),
                    itemBuilder: (_, i) {
                      final l = leads[i];
                      final who = author(l.createdBy);
                      final at = l.createdAt;
                      final time = at == null
                          ? ''
                          : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
                      final displayName = l.name.trim().isEmpty
                          ? (l.phone ?? 'Без имени')
                          : l.name;
                      final apptDate = l.appointmentDate == null
                          ? ''
                          : dateRu(l.appointmentDate!);
                      final apptTime = (l.appointmentTime ?? '').trim();
                      final initial = displayName.trim().isEmpty
                          ? '?'
                          : displayName.trim().substring(0, 1).toUpperCase();
                      final avatarColor = _colorFor(displayName);
                      return PressScale(
                        scale: 0.99,
                        onTap: () => Navigator.pop(context, l),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 10, 14, 10),
                          child: Row(
                            children: [
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    width: 42,
                                    height: 42,
                                    alignment: Alignment.center,
                                    decoration: ShapeDecoration(
                                      color: avatarColor.withValues(
                                        alpha: 0.14,
                                      ),
                                      shape: squircle(14),
                                    ),
                                    child: Text(
                                      initial,
                                      style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800,
                                        color: avatarColor,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: -3,
                                    bottom: -3,
                                    child: Container(
                                      width: 17,
                                      height: 17,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: kTeal,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: t.card,
                                          width: 2,
                                        ),
                                      ),
                                      child: const Icon(
                                        Iconsax.flash_1,
                                        size: 8.5,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: t.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        if ((l.phone ?? '').isNotEmpty)
                                          Text(
                                            '+${l.phone}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: t.textSecondary,
                                            ),
                                          ),
                                        if (apptDate.isNotEmpty ||
                                            apptTime.isNotEmpty)
                                          _pill(
                                            t,
                                            Iconsax.calendar_1,
                                            [apptDate, apptTime]
                                                .where((s) => s.isNotEmpty)
                                                .join(' · '),
                                          ),
                                        if (who.isNotEmpty)
                                          _pill(t, Iconsax.user, who),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    time,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: t.textTertiary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 17,
                                    color: t.textTertiary,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Маленькая пилюля с иконкой — дата приёма или имя менеджера под именем
  /// лида, вместо ряда через « · », как было раньше.
  Widget _pill(AppTokens t, IconData icon, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: ShapeDecoration(color: t.fill, shape: squircle(8)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: t.textSecondary),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: t.textSecondary,
          ),
        ),
      ],
    ),
  );
}

/// Мини-метка «VIP» / «ЛИД» рядом с именем в списке чатов.
class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.bg,
    required this.fg,
    this.gapLeft = 6,
    this.gapRight = 0,
  });
  final String label;
  final Color bg;
  final Color fg;

  /// Отступы вокруг метки. Рядом с именем нужен отступ слева, а в начале
  /// строки-превью — наоборот, справа: иначе метка «уезжает» от левого края
  /// и не встаёт в одну колонку с именем над ней.
  final double gapLeft;
  final double gapRight;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(left: gapLeft, right: gapRight),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          color: fg,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Есть ли assets/vip.png (проверяется один раз при старте экрана чатов).
bool? vipAssetExists;

/// Аватар чата: обычный — флаг страны; VIP — assets/vip.png (фолбэк — корона);
/// лид — флаг с тил-бейджем-молнией.
class _ChatAvatar extends StatelessWidget {
  const _ChatAvatar({
    required this.phone,
    required this.isVip,
    required this.isLead,
  });
  final String phone;
  final bool isVip;
  final bool isLead;

  @override
  Widget build(BuildContext context) {
    const size = 50.0;
    return _content(size, BorderRadius.circular(size * 0.3));
  }

  Widget _content(double size, BorderRadius radius) {
    if (isVip) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: const Color(0xFFE7C14A), width: 1.4),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFE7C14A).withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
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
                  child: const Icon(
                    Iconsax.crown_1,
                    color: Color(0xFFFFE9A8),
                    size: 26,
                  ),
                ),
        ),
      );
    }

    // Telegram-чат без номера — синий аватар с самолётиком. Когда клиент
    // поделился номером: +7 6xx/7xx — флаг Казахстана, прочие +7 — России,
    // другие коды стран — глобус.
    final isTg = phone.startsWith('tg_');
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    final other = !isTg && digits.isNotEmpty && !digits.startsWith('7');
    final flag = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: Colors.black.withValues(alpha: 0.07)),
        color: isTg
            ? const Color(0xFF229ED9)
            : (other ? const Color(0xFF5A6ACF) : null),
        image: isTg || other
            ? null
            : DecorationImage(
                image: AssetImage(flagAsset(phone)),
                fit: BoxFit.cover,
              ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: isTg
          ? const Icon(Icons.telegram, color: Colors.white, size: 30)
          : other
          ? const Icon(Iconsax.global, color: Colors.white, size: 26)
          : null,
    );
    if (!isLead) return flag;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
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
        ],
      ),
    );
  }
}

/// «N в сети» (presence из Firestore). Тап — список имён.
class _FbOnlineBadge extends ConsumerWidget {
  const _FbOnlineBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Кэшированный provider вместо StreamBuilder — без лишних подписок.
    final online =
        ref.watch(presenceUsersProvider).value ?? const <PresenceUser>[];
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF6BF29B),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '${online.length} в сети',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showList(
    BuildContext context,
    WidgetRef ref,
    List<PresenceUser> online,
  ) {
    final me = ref.read(appConfigProvider).userId;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      color: Color(0xFF2ECC71),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Text(
                    'В системе сейчас — ${online.length}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            for (final u in online)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.brand.withValues(alpha: 0.15),
                  child: Text(
                    (u.name.isNotEmpty ? u.name[0] : '?').toUpperCase(),
                    style: const TextStyle(
                      color: AppColors.brand,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                title: Text(
                  u.name.isEmpty ? 'Менеджер' : u.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                trailing: u.uid == me
                    ? const Text(
                        'вы',
                        style: TextStyle(
                          color: AppColors.brand,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
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
  bool _hasText = false;

  late final FirestoreChatRepository _repo = ref.read(
    firestoreChatRepositoryProvider,
  );
  bool get _isTelegram => widget.conversation.isTelegram;

  /// Мы писали heartbeat «печатаю» — надо снять при выходе/очистке.
  bool _typedSomething = false;

  /// Когда в последний раз отправляли heartbeat (ограничитель частоты).
  DateTime? _lastTypingPing;

  /// Отложенное сохранение черновика: пишем через паузу после набора, а не
  /// на каждую букву и не в dispose (Riverpod запрещает менять провайдер во
  /// время разрушения дерева).
  Timer? _draftTimer;

  /// Обновление подзаголовка «отвечает …», чтобы он гас без событий Firestore.
  Timer? _headerTicker;

  /// Висел ли индикатор на прошлом тике (нужен один финальный ребилд).
  bool _wasTypingByOther = false;

  /// Менеджеры для подписи автора сообщения. Обновляется в build.
  List<Map<String, dynamic>> _managers = const [];

  /// Цвет переписки по мессенджеру: Telegram — акцент дизайн-системы,
  /// WhatsApp — его зелёный. Пузыри, кнопка отправки и мелкие акценты
  /// красятся вместе, иначе чат выглядит «чужим».
  static const _waBubble = LinearGradient(
    colors: [Color(0xFF25D366), Color(0xFF128C7E)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  LinearGradient _grad(AppTokens t) => _isTelegram ? t.accent : _waBubble;
  Color _tint(AppTokens t) =>
      _isTelegram ? t.accentSolid : const Color(0xFF12A46B);
  List<BoxShadow> _glow(AppTokens t) => [
    BoxShadow(
      color: _tint(t).withValues(alpha: t.isDark ? 0.34 : 0.28),
      blurRadius: 22,
      offset: const Offset(0, 10),
    ),
  ];

  /// Черновики: ссылку берём в initState. В dispose обращаться к ref нельзя —
  /// Riverpod к этому моменту его уже закрыл («Cannot use ref after the
  /// widget was disposed»), а сохранить недописанное надо именно на выходе.
  late final DraftsController _drafts;

  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  int _recSeconds = 0;
  Timer? _recTimer;

  /// Прокрутка ленты сообщений + видимость кнопки «в конец переписки».
  final _msgScroll = ScrollController();
  bool _showJumpDown = false;

  /// Мягкий замок от двойных ответов: момент входа в чат (кто раньше вошёл —
  /// тот и отвечает), heartbeat «я в чате» и осознанный обход замка.
  final DateTime _enteredAt = DateTime.now();
  Timer? _viewTimer;
  bool _lockOverride = false;
  String? _viewUid;
  String? _recPath;

  FsMessage? _replyTo; // сообщение, на которое отвечаем

  /// Сообщения, отправленные только что: показываются в чате СРАЗУ, не
  /// дожидаясь ответа сервера и Firestore. Исчезают, как только приходит
  /// настоящий документ (сверка — в waitingPending, там же тесты).
  final List<PendingMsg> _pending = [];

  /// Пузырь для ещё не подтверждённого сервером сообщения.
  FsMessage _pendingBubble(PendingMsg p) => FsMessage(
    id: p.localId,
    direction: 'outbound',
    type: p.type,
    text: p.text.isEmpty ? null : p.text,
    contentUri: null,
    // Локальный путь вместо ссылки: пузырь показывает файл с устройства,
    // пока он ещё грузится в Storage.
    mediaUrl: p.localPath,
    fileName: p.fileName,
    status: 'sending',
    createdAt: p.createdAt,
    isEdited: false,
    isDeleted: false,
    replyToText: p.replyToText,
    authorId: ref.read(appConfigProvider).userId,
  );

  // Блокировка контакта (скрытие из списка, без пушей/автоответов).
  late bool _blocked = widget.conversation.blocked;

  Future<void> _toggleBlock() async {
    final block = !_blocked;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          block ? 'Заблокировать контакта?' : 'Разблокировать контакта?',
        ),
        content: Text(
          block
              ? 'Чат скроется из списка (найти можно поиском), пуши и автоответы для этого контакта отключатся. Сообщения продолжат сохраняться.'
              : 'Чат вернётся в список, пуши и автоответы снова заработают.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: block
                  ? const Color(0xFFC6403C)
                  : AppColors.brand,
            ),
            onPressed: () => Navigator.pop(d, true),
            child: Text(block ? 'Заблокировать' : 'Разблокировать'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(firestoreChatRepositoryProvider)
          .setBlocked(widget.conversation.id, block);
      if (mounted) {
        setState(() => _blocked = block);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              block ? 'Контакт заблокирован' : 'Контакт разблокирован',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _drafts = ref.read(draftsProvider.notifier);
    // Кнопка «в конец переписки»: показываем после двух экранов прокрутки.
    _msgScroll.addListener(() {
      final show = _msgScroll.hasClients && _msgScroll.offset > 900;
      if (show != _showJumpDown) setState(() => _showJumpDown = show);
    });
    // «Я в этом чате»: остальные менеджеры видят это сразу при открытии —
    // не дожидаясь, пока начнём печатать. Heartbeat раз в 20 секунд; если
    // приложение умерло, отметка протухает сама через 45 секунд.
    {
      final cfg = ref.read(appConfigProvider);
      final uid = _viewUid = cfg.userId;
      if (uid != null && uid.isNotEmpty) {
        void beat() => _repo
            .setViewing(widget.conversation.id,
                uid: uid, name: (cfg.userName ?? '').trim(), since: _enteredAt)
            .catchError((_) {});
        beat();
        _viewTimer = Timer.periodic(const Duration(seconds: 20), (_) {
          beat();
          // Заодно перепроверяем замок: если коллега вышел некрасиво
          // (приложение убито), его отметка протухает — замок должен упасть
          // сам, без нового события из Firestore.
          if (mounted) setState(() {});
        });
      }
    }
    // Недописанное сообщение возвращаем на место — менеджер часто выходит
    // из чата посмотреть запись и возвращается.
    final draft = ref.read(draftsProvider)[widget.conversation.id];
    if (draft != null && draft.isNotEmpty) {
      _input.text = draft;
      _input.selection = TextSelection.fromPosition(
        TextPosition(offset: draft.length),
      );
      _hasText = true;
    }
    _input.addListener(() {
      final has = _input.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
      // Черновик сохраняем через 700 мс после последней буквы.
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(milliseconds: 700), _saveDraft);
      // Telegram: пока менеджер печатает — heartbeat в диалог, остальные
      // видят «отвечает [имя]» (защита от двойных ответов).
      if (_isTelegram) {
        final cfg = ref.read(appConfigProvider);
        if (has) {
          _typedSomething = true;
          // Не чаще раза в 3 секунды: раньше heartbeat уходил в Firestore на
          // КАЖДУЮ букву — сеть, деньги и подтормаживание ввода на слабых
          // телефонах. Индикатор у коллег живёт 12 секунд, трёх хватает.
          final now = DateTime.now();
          if (_lastTypingPing == null ||
              now.difference(_lastTypingPing!) > const Duration(seconds: 3)) {
            _lastTypingPing = now;
            _repo
                .typingHeartbeat(
                  conversationId: widget.conversation.id,
                  uid: cfg.userId ?? '',
                  name: (cfg.userName ?? '').trim().isNotEmpty
                      ? cfg.userName!.trim()
                      : 'Менеджер',
                )
                .catchError((_) {});
          }
        } else if (_typedSomething) {
          _typedSomething = false;
          _lastTypingPing = null;
          _repo.clearTyping(widget.conversation.id).catchError((_) {});
        }
      }
    });
    _repo.markRead(widget.conversation.id).catchError((_) {});
    // Запоминаем открытый чат: Android в фоне убивает приложение, и при
    // возврате менеджер оказывался в списке вместо переписки. При следующем
    // запуске MainShell откроет этот чат обратно. Штатный выход из чата
    // (dispose) отметку снимает — восстановление только после гибели процесса.
    //
    // openChatUid — чей это чат: устройство общее (правило «один менеджер
    // в системе» подразумевает, что менеджеры сменяют друг друга на одном
    // телефоне). Без этой метки менеджер B, зайдя после того как процесс
    // убило под менеджером A, оказывался бы в чужом открытом чате A.
    final myUid = ref.read(appConfigProvider).userId ?? '';
    SharedPreferences.getInstance().then((p) {
      p.setString('openChatId', widget.conversation.id);
      p.setInt('openChatAt', DateTime.now().millisecondsSinceEpoch);
      p.setString('openChatUid', myUid);
    });
    if (_isTelegram) {
      // Клиент в Telegram видит «печатает…», когда менеджер открыл чат.
      _repo.notifyTelegramTyping(widget.conversation.id);
      // Тик только когда в чате реально висит чужое «отвечает …»: раньше он
      // перестраивал ВЕСЬ экран каждые 5 секунд (все пузыри, волны, тени) —
      // на слабых Android это ровно те подёргивания, из-за которых не
      // открывалась клавиатура.
      _headerTicker = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted) return;
        final live = ref
            .read(conversationDocProvider(widget.conversation.id))
            .value;
        final typing =
            live?.typingByOther(ref.read(appConfigProvider).userId) ?? false;
        // Перерисовываем, пока индикатор висит, и ещё один раз — чтобы он
        // погас, когда чужой heartbeat протух.
        if (typing || _wasTypingByOther) setState(() {});
        _wasTypingByOther = typing;
      });
    }
  }

  @override
  void dispose() {
    _headerTicker?.cancel();
    // Финальное сохранение — ПОСЛЕ разрушения дерева: менять провайдер прямо
    // в dispose Riverpod не даёт («Tried to modify a provider while the widget
    // tree was building»). Контроллер черновиков живёт всё приложение, так
    // что отложенный вызов безопасен.
    _loadWatch?.cancel();
    _draftTimer?.cancel();
    final draftText = _input.text;
    final drafts = _drafts;
    final chatId = widget.conversation.id;
    Future(() => drafts.set(chatId, draftText));
    if (_typedSomething) {
      _repo.clearTyping(widget.conversation.id).catchError((_) {});
    }
    // Чат закрыт руками — восстанавливать при запуске нечего.
    SharedPreferences.getInstance().then((p) {
      p.remove('openChatId');
      p.remove('openChatUid');
    });
    _recTimer?.cancel();
    _viewTimer?.cancel();
    // Снимаем «я в чате», чтобы замок не держался лишние 45 секунд.
    if (_viewUid != null && _viewUid!.isNotEmpty) {
      _repo.clearViewing(widget.conversation.id, _viewUid!).catchError((_) {});
    }
    _recorder.dispose();
    _input.dispose();
    _msgScroll.dispose();
    // Голосовое не должно играть в пустоту после выхода из чата: панель
    // управления живёт только здесь, снаружи его не остановить.
    VoiceController.I.stop();
    super.dispose();
  }

  /// Что подставлять в карточки лида / массажа / VIP из чата.
  ///
  /// Телефон — только настоящий: у телеграм-чата, где клиент ещё не поделился
  /// номером, его нет, и подставлять туда `tg_123456789` нельзя. Имя — только
  /// если это не сам номер (иначе поле «Имя» заполнялось бы телефоном), и
  /// берётся из ЖИВОГО документа: телеграм-ник мог смениться на номер уже
  /// после открытия чата.
  ({String name, String phone}) _cardPrefill() {
    final c = _live;
    final digits = (c.phone ?? '').replaceAll(RegExp(r'\D'), '');
    final raw = c.name.trim();
    final nameIsPhone =
        raw.isNotEmpty && raw.replaceAll(RegExp(r'[\d\s+()\-]'), '').isEmpty;
    return (name: nameIsPhone ? '' : raw, phone: digits);
  }

  /// WhatsApp Business API: клиент молчит больше 24 часов, Meta не пропустит
  /// обычный текст. Спрашиваем менеджера — отправлять ли приглашение
  /// одобренным шаблоном (автоматически такое не уходит).
  Future<bool> _askSendOpener() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Клиент давно не писал'),
        content: const Text(
          'Прошло больше 24 часов с последнего сообщения клиента — WhatsApp не пропустит '
          'обычный текст.\n\nОтправить приглашение одобренным шаблоном? Ваш текст уйдёт '
          'сразу после того, как клиент ответит.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Не отправлять'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kTeal),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Отправить приглашение'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// Закрытое окно WABA приходит с сервера как ошибка WINDOW_CLOSED.
  static bool _isWindowClosed(Object e) =>
      e.toString().contains('WINDOW_CLOSED');

  /// Пока у клиента нет номера: тап по шапке отправляет ему «напишите нам
  /// ваш номер» + кнопку «Поделиться номером».
  Future<void> _askClientPhone() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Запросить номер?'),
        content: const Text(
          'Клиенту уйдёт сообщение «Напишите нам, пожалуйста, ваш номер телефона» с кнопкой «Поделиться номером».',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kTeal),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Отправить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _repo.requestPhone(widget.conversation.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Запрос номера отправлен')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
      }
    }
  }

  /// Живой документ диалога (typing/ответственный), fallback — снапшот входа.
  /// Подписка ТОЛЬКО на свой документ: от событий чужих чатов экран чата не
  /// перестраивается (иначе на части Android не открывалась клавиатура).
  FsConversation get _live =>
      ref.watch(conversationDocProvider(widget.conversation.id)).value ??
      widget.conversation;

  // Автотекста после звонка больше нет (убран 2026-08-09): клиенту пишет
  // менеджер сам. В переписке остаётся только отметка о звонке.

  Future<void> _callPhone(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri.parse('tel:$digits');
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw Exception('нет приложения для звонка');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не удалось позвонить: $e')));
      }
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Чем закончился звонок?',
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    color: kInk,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(
                Iconsax.call_calling,
                color: Color(0xFF23A35F),
              ),
              title: const Text(
                'Дозвонился',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('Отметить в переписке'),
              onTap: () => Navigator.pop(sheet, 'answered'),
            ),
            ListTile(
              leading: const Icon(Iconsax.call_slash, color: Color(0xFFC6403C)),
              title: const Text(
                'Не ответил',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('Отметить и написать «пишите в чат»'),
              onTap: () => Navigator.pop(sheet, 'noAnswer'),
            ),
            ListTile(
              leading: const Icon(Iconsax.close_circle, color: kSub),
              title: const Text(
                'Не записывать',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              onTap: () => Navigator.pop(sheet),
            ),
            const SizedBox(height: 8),
          ],
        ),
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
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не записалось: $e')));
      }
    }
  }

  Future<void> _startRec() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Нет доступа к микрофону')),
          );
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      // Моно 64 кбит/с 44.1 кГц: голос звучит так же, а файл в 5 раз меньше.
      // На настройках по умолчанию две секунды весили 87 КБ — длинные записи
      // упирались в лимит вложения WhatsApp.
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      _recPath = path;
      Haptics.success();
      setState(() {
        _recording = true;
        _recSeconds = 0;
      });
      _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recSeconds++);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Запись не началась: $e')));
      }
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
      if (tooShort && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Слишком коротко')));
      }
      return;
    }
    // Пузырь голосового появляется сразу, файл уходит фоном.
    try {
      final bytes = await File(path).readAsBytes();
      await _sendMediaOptimistic(
        bytes: bytes,
        fileName: 'voice.m4a',
        mime: 'audio/mp4',
        kind: 'audio',
        localPath: path,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Голосовое не отправлено: $e')));
      }
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (s) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Фото из галереи'),
              onTap: () => Navigator.pop(s, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Камера'),
              onTap: () => Navigator.pop(s, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Файл'),
              onTap: () => Navigator.pop(s, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    List<int>? bytes;
    String? fileName;
    String? mime;
    String kind = 'document';
    String? localPath;
    try {
      if (choice == 'gallery' || choice == 'camera') {
        final x = await ImagePicker().pickImage(
          source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
          imageQuality: 85,
        );
        if (x == null) return;
        bytes = await x.readAsBytes();
        fileName = x.name;
        mime = x.mimeType ?? 'image/jpeg';
        kind = 'image';
        localPath = x.path;
      } else {
        final res = await FilePicker.platform.pickFiles(withData: true);
        final f = res?.files.isNotEmpty == true ? res!.files.first : null;
        if (f == null || f.bytes == null) return;
        bytes = f.bytes!;
        fileName = f.name;
        mime = 'application/octet-stream';
        kind = 'document';
        localPath = f.path;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не удалось выбрать: $e')));
      }
      return;
    }

    // Локальные копии: внутри замыкания Dart не выводит non-null у изменяемых
    // переменных, объявленных выше (все три уже заполнены — ранние return
    // выше это гарантируют).
    final mediaBytes = bytes;
    final mediaName = fileName;
    final mediaMime = mime;
    await _sendMediaOptimistic(
      bytes: mediaBytes,
      fileName: mediaName,
      mime: mediaMime,
      kind: kind,
      localPath: localPath,
    );
  }

  /// Отправка вложения без ожидания: пузырь появляется сразу, загрузка идёт
  /// фоном. Раньше поле ввода блокировалось спиннером и сообщение возникало
  /// только после ответа сервера.
  Future<void> _sendMediaOptimistic({
    required List<int> bytes,
    required String fileName,
    required String mime,
    required String kind,
    String? localPath,
  }) async {
    final pending = PendingMsg(
      text: '',
      type: kind,
      localPath: localPath,
      fileName: fileName,
    );
    setState(() {
      _pending
        ..removeWhere(
          (p) =>
              DateTime.now().difference(p.createdAt) >
              const Duration(minutes: 5),
        )
        ..add(pending);
    });

    final repo = ref.read(firestoreChatRepositoryProvider);
    Future<void> put({bool opener = false}) => repo.sendMedia(
      phone: widget.conversation.phone ?? widget.conversation.id,
      conversationId: widget.conversation.id,
      bytes: bytes,
      fileName: fileName,
      contentType: mime,
      kind: kind,
      name: widget.conversation.name,
      sendOpener: opener,
    );
    try {
      try {
        await put();
      } catch (e) {
        if (!_isWindowClosed(e) || !mounted) rethrow;
        if (!await _askSendOpener()) {
          if (mounted) setState(() => _pending.remove(pending));
          return;
        }
        await put(opener: true);
      }
    } catch (e) {
      if (mounted) {
        Haptics.error();
        setState(() => _pending.remove(pending));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
      }
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final reply = _replyTo;
    _input.clear();
    _drafts.clear(widget.conversation.id);
    Haptics.tap();

    // Пузырь появляется мгновенно — менеджер не ждёт ни сервер, ни Firestore.
    final pending = PendingMsg(text: text, replyToText: reply?.text);
    setState(() {
      _replyTo = null;
      _pending
        ..removeWhere(
          (p) =>
              DateTime.now().difference(p.createdAt) >
              const Duration(minutes: 5),
        )
        ..add(pending);
    });

    if (_isTelegram && _typedSomething) {
      // Индикатор «отвечает…» гасим сразу (сервер продублирует при записи).
      _typedSomething = false;
      _repo.clearTyping(widget.conversation.id).catchError((_) {});
    }
    final repo = ref.read(firestoreChatRepositoryProvider);
    Future<String?> send({bool opener = false}) => repo.sendText(
      phone: widget.conversation.phone ?? widget.conversation.id,
      conversationId: widget.conversation.id,
      text: text,
      name: widget.conversation.name,
      refMessageId: reply?.id,
      replyToText: reply?.text,
      sendOpener: opener,
    );

    try {
      String? id;
      try {
        id = await send();
      } catch (e) {
        // Окно WABA закрыто — спрашиваем менеджера и повторяем с согласием.
        if (!_isWindowClosed(e) || !mounted) rethrow;
        if (!await _askSendOpener()) {
          if (mounted) {
            setState(() => _pending.remove(pending));
            _input.text = text;
          }
          return;
        }
        id = await send(opener: true);
      }
      // Дальше пузырь живёт, пока не придёт настоящий документ с этим id.
      if (mounted) setState(() => pending.serverId = id);
    } catch (e) {
      if (mounted) {
        Haptics.error();
        setState(() => _pending.remove(pending));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не отправлено: $e')));
        _input.text = text;
      }
    }
  }

  /// Меню действий над сообщением: как в мессенджерах — фон затемняется,
  /// сам пузырь остаётся на своём месте, рядом всплывает компактная карточка.
  ///
  /// [anchor] — прямоугольник пузыря на экране: по нему решаем, показать меню
  /// сверху или снизу и к какому краю прижать.
  void _showMessageActions(FsMessage m, Rect anchor) {
    // Пузырь ещё не подтверждён сервером — править и удалять нечего.
    if (m.id.startsWith('local_') || m.isDeleted) return;
    // Сообщение в очереди ещё не ушло — его можно только снять с отправки.
    // В Telegram бот правит/удаляет только СВОИ сообщения (ответ владельца
    // с телефона через Telegram Business боту не принадлежит).
    final canEditDelete =
        m.isOutbound &&
        (!_isTelegram || m.authorId != null) &&
        (m.status == 'sent' ||
            m.status == 'delivered' ||
            m.status == 'read' ||
            m.status == 'accepted' ||
            m.status == 'queued');

    final hasText = m.text != null && m.text!.isNotEmpty;
    Haptics.select();
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        // Анимацию ведёт само меню, маршруту анимировать нечего — иначе после
        // закрытия остаётся «мёртвая» пауза в 180 мс.
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => _MessageMenu(
          anchor: anchor,
          alignRight: m.isOutbound,
          bubble: _bubbleBody(
            m,
            Theme.of(context).brightness == Brightness.dark,
          ),
          actions: [
            (
              Icons.reply_rounded,
              'Ответить',
              false,
              () => setState(() => _replyTo = m),
            ),
            if (hasText)
              (
                Icons.copy_rounded,
                'Копировать',
                false,
                () {
                  Clipboard.setData(ClipboardData(text: m.text!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Скопировано'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            if (canEditDelete && m.type == 'text')
              (Icons.edit_rounded, 'Изменить', false, () => _editMessage(m)),
            if (canEditDelete)
              (Icons.delete_rounded, 'Удалить', true, () => _deleteMessage(m)),
          ],
        ),
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
        content: TextField(
          controller: c,
          minLines: 1,
          maxLines: 6,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, c.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    // Диалог ещё проигрывает анимацию закрытия и держит TextField —
    // немедленный dispose роняет сборку («used after being disposed»).
    Future.delayed(const Duration(milliseconds: 600), c.dispose);
    if (newText == null || newText.isEmpty || newText == m.text) return;
    try {
      await ref
          .read(firestoreChatRepositoryProvider)
          .editText(
            messageId: m.id,
            text: newText,
            conversationId: widget.conversation.id,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не изменено: $e')));
      }
    }
  }

  Future<void> _deleteMessage(FsMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Удалить сообщение?'),
        content: Text(
          _isTelegram
              ? 'Будет удалено и у клиента в Telegram.'
              : 'Будет удалено и у клиента в WhatsApp.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(firestoreChatRepositoryProvider)
          .deleteMessage(m.id, conversationId: widget.conversation.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не удалено: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Живой документ диалога: номер, ответственный, «отвечает …».
    final live = _live;
    // Подписки только здесь: в itemBuilder (_bubble) обращаться к провайдерам
    // нельзя — переписка начинает пересобираться на каждую строку.
    _managers =
        ref.watch(managersProvider).value ?? const <Map<String, dynamic>>[];
    final phone =
        live.phone ?? widget.conversation.phone ?? widget.conversation.id;
    final hasPhone = (live.phone ?? '').trim().isNotEmpty;
    final me = ref.read(appConfigProvider).userId;
    final typingBy = live.typingByOther(me)
        ? (live.typingName ?? 'менеджер')
        : null;
    // Пока номера нет — вместо подзаголовка кнопка «запросить номер».
    final askPhoneMode = _isTelegram && !hasPhone && typingBy == null;
    final String? subtitle = typingBy != null
        ? 'отвечает $typingBy…'
        : askPhoneMode
        ? 'Напишите нам ваш номер — отправить'
        : (live.responsibleName ?? '').trim().isNotEmpty
        ? 'ведёт ${live.responsibleName!.trim()}'
        : null;
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: _chatBar(
          live: live,
          phone: phone,
          subtitle: subtitle,
          askPhoneMode: askPhoneMode,
          typing: typingBy != null,
          dark: dark,
        ),
      ),
      body: Stack(
        children: [
          // Обои переписки: свои картинки под тему. Файла нет в сборке —
          // errorBuilder молча оставляет однотонный фон.
          Positioned.fill(child: ColoredBox(color: context.tokens.surface)),
          Positioned.fill(
            child: Image.asset(
              dark ? 'assets/chat_bg/dark.png' : 'assets/chat_bg/light.png',
              fit: BoxFit.cover,
              // Обои не должны «дышать» вместе с клавиатурой: выравниваем по
              // верху, тогда при её появлении картинка стоит на месте.
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ref
                    .watch(firebaseMessagesProvider(widget.conversation.id))
                    .when(
                      loading: _loadingMessages,
                      error: (e, _) {
                        // Ошибку видно и в приложении, и в удалённом журнале —
                        // «вечная загрузка» без причины больше не повторится.
                        DiagService.instance.log(
                          'CHAT ошибка ${widget.conversation.id}: $e',
                        );
                        return _loadFailed('$e');
                      },
                      data: (loaded) {
                        if (_loadStartedAt != null) {
                          final ms = DateTime.now()
                              .difference(_loadStartedAt!)
                              .inMilliseconds;
                          if (ms > 2000) {
                            DiagService.instance.log(
                              'CHAT первый снимок $ms мс, сообщений ${loaded.length}',
                            );
                          }
                          _loadStartedAt = null;
                          _loadRetries = 0;
                          _loadGaveUp = false;
                          _loadWatch?.cancel();
                          _loadWatch = null;
                        }
                        // Свежеотправленные пузыри показываем поверх загруженных,
                        // пока Firestore не отдаст настоящий документ. Правила
                        // сверки — в waitingPending (data/pending_match.dart),
                        // они накрыты тестами.
                        final meUid = ref.read(appConfigProvider).userId;
                        final waiting = waitingPending(
                          loaded: loaded,
                          pending: _pending,
                          meUid: meUid,
                          now: DateTime.now(),
                        );
                        final msgs = waiting.isEmpty
                            ? loaded
                            : [...loaded, ...waiting.map(_pendingBubble)];
                        // id → позиция: без этого ключи строк не работали.
                        final rowById = <String, int>{
                          for (var j = 0; j < msgs.length; j++)
                            msgs[j].id: msgs.length - 1 - j,
                        };
                        return ListView.builder(
                          reverse: true,
                          controller: _msgScroll,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          itemCount: msgs.length,
                          // Куда переехала строка с этим ключом. Без коллбэка
                          // список сопоставляет строки ПО ПОЗИЦИИ: новое
                          // сообщение сдвигало все строки на одну, ключи на
                          // местах не совпадали, и Flutter пересоздавал каждую
                          // строку заново — играющее голосовое обрывалось на
                          // любом входящем.
                          findChildIndexCallback: (key) =>
                              rowById[(key as ValueKey<String>).value],
                          itemBuilder: (context, i) {
                            final idx = msgs.length - 1 - i;
                            final m = msgs[idx];
                            // Разделитель даты — как в WhatsApp: перед первым
                            // сообщением нового дня.
                            final prev = idx > 0 ? msgs[idx - 1] : null;
                            final next = idx < msgs.length - 1
                                ? msgs[idx + 1]
                                : null;
                            final newDay =
                                m.createdAt != null &&
                                (prev?.createdAt == null ||
                                    !_sameDay(prev!.createdAt!, m.createdAt!));
                            // Группировка подряд идущих сообщений одной
                            // стороны: хвостик — только у последнего в серии,
                            // между своими — плотный зазор. Без этого каждое
                            // сообщение стояло отдельным пузырём, как в SMS.
                            final first = prev == null ||
                                newDay ||
                                !_sameBubbleGroup(prev, m);
                            final tail =
                                next == null || !_sameBubbleGroup(m, next);
                            return Column(
                              // Ключ по id: при обновлении списка (новый статус,
                              // новое сообщение) Flutter сопоставляет строки по
                              // ключу, а не по позиции, и не пересобирает всё.
                              key: ValueKey(m.id),
                              children: [
                                if (newDay) _dateChip(m.createdAt!, dark),
                                _cachedBubble(m, dark,
                                    first: first, tail: tail),
                              ],
                            );
                          },
                        );
                      },
                    ),
                    ),
                    // Кнопка «в конец переписки»: появляется, когда ушли
                    // вверх больше чем на пару экранов. Быстрее, чем мотать
                    // пальцем сотню сообщений обратно.
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: AnimatedScale(
                        scale: _showJumpDown ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutBack,
                        child: PressScale(
                          onTap: () => _msgScroll.animateTo(
                            0,
                            duration: const Duration(milliseconds: 350),
                            curve: Curves.easeOutCubic,
                          ),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: (dark
                                      ? context.tokens.cardElevated
                                      : Colors.white)
                                  .withValues(alpha: 0.96),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: context.tokens.separator,
                                width: 0.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.12),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 26,
                              color: _tint(context.tokens),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // «Сейчас играет»: пауза/скорость/стоп под рукой, даже когда
              // пузырь голосового давно прокручен за экран.
              ListenableBuilder(
                listenable: VoiceController.I,
                builder: (_, _) => VoiceController.I.url == null
                    ? const SizedBox.shrink()
                    : _voiceBar(dark),
              ),
              if (_live.aiSuggestion != null) _aiSuggestionBar(dark, _live.aiSuggestion!),
              if (_replyTo != null) _replyBar(dark),
              // Мягкий замок: в чате уже сидит коллега, вошедший раньше —
              // вместо поля ввода плашка. Обойти можно, но осознанно.
              Builder(builder: (_) {
                final other = live.viewerOther(me);
                final locked = !_lockOverride &&
                    other != null &&
                    (other.since ?? DateTime(0)).isBefore(_enteredAt);
                return locked ? _lockBar(dark, other.name) : _composer(dark);
              }),
            ],
          ),
        ],
      ),
    );
  }

  /// Плашка вместо поля ввода, когда в чате уже отвечает коллега.
  /// Не жёсткий запрет: кнопка «Всё равно ответить» открывает ввод — но
  /// дублирование становится осознанным решением, а не случайностью.
  Widget _lockBar(bool dark, String name) {
    final t = context.tokens;
    final who = name.isEmpty ? 'другой менеджер' : name;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (dark ? t.cardElevated : t.card).withValues(alpha: 0.97),
        border: Border(top: BorderSide(color: t.separator, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 18, color: t.textTertiary),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Отвечает $who',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: t.textPrimary,
                      ),
                    ),
                    Text(
                      'Чат занят — не дублируйте ответ',
                      style: TextStyle(fontSize: 11.5, color: t.textTertiary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _lockOverride = true),
                child: const Text(
                  'Всё равно ответить',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Полоска «сейчас играет» над полем ввода: играющее голосовое можно
  /// поставить на паузу, домотать или заглушить, не ища его пузырь в ленте.
  Widget _voiceBar(bool dark) {
    final t = context.tokens;
    final vc = VoiceController.I;
    final player = vc.url == null ? null : vc.playerOf(vc.url!);
    final tint = _tint(t);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (dark ? t.cardElevated : t.card).withValues(alpha: 0.97),
        border: Border(top: BorderSide(color: t.separator, width: 0.5)),
      ),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 6),
            PressScale(
              scale: 0.9,
              onTap: () => vc.url != null ? vc.toggle(vc.url!) : null,
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(
                  vc.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: tint,
                  size: 24,
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<Duration>(
                stream: player?.positionStream,
                builder: (_, snap) {
                  final pos = snap.data ?? Duration.zero;
                  final dur = player?.duration ?? Duration.zero;
                  final frac = dur.inMilliseconds == 0
                      ? 0.0
                      : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
                  String fmt(Duration d) =>
                      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vc.loading
                            ? 'Загрузка голосового…'
                            : 'Голосовое · ${fmt(pos)} / ${fmt(dur)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: t.textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Тонкая полоса прогресса; тап по ней — перемотка.
                      LayoutBuilder(
                        builder: (_, c) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) => vc.url == null
                              ? null
                              : vc.seekTo(vc.url!, d.localPosition.dx / c.maxWidth),
                          child: SizedBox(
                            height: 8,
                            child: Center(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: SizedBox(
                                  height: 3,
                                  width: c.maxWidth,
                                  child: Stack(children: [
                                    Container(color: tint.withValues(alpha: 0.18)),
                                    FractionallySizedBox(
                                      widthFactor: frac,
                                      child: Container(color: tint),
                                    ),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            PressScale(
              scale: 0.92,
              onTap: vc.cycleSpeed,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: ShapeDecoration(
                  color: tint.withValues(alpha: 0.10),
                  shape: squircle(9),
                ),
                child: Text(
                  '${vc.speed == 1 ? '1' : vc.speed.toString().replaceAll('.0', '')}×',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: tint),
                ),
              ),
            ),
            PressScale(
              scale: 0.9,
              onTap: vc.stop,
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(Icons.close_rounded, size: 20, color: t.textTertiary),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  /// Шапка переписки: аватар с меткой мессенджера, имя и живой подзаголовок,
  /// круглые кнопки действий. Полупрозрачная — обои переписки просвечивают,
  /// снизу волосяная линия вместо тени.
  Widget _chatBar({
    required FsConversation live,
    required String phone,
    required String? subtitle,
    required bool askPhoneMode,
    required bool typing,
    required bool dark,
  }) {
    final t = context.tokens;
    final accent = _isTelegram
        ? const Color(0xFF229ED9)
        : const Color(0xFF25D366);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (dark ? t.cardElevated : t.card).withValues(alpha: 0.94),
        border: Border(bottom: BorderSide(color: t.separator, width: 0.5)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              _barIcon(
                Icons.arrow_back_ios_new_rounded,
                'Назад',
                () => Navigator.of(context).maybePop(),
                size: 18,
              ),
              // Аватар с меткой мессенджера в углу.
              SizedBox(
                width: 42,
                height: 42,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: ShapeDecoration(
                        color: t.fill,
                        shape: const CircleBorder(),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.asset(flagAsset(phone), fit: BoxFit.cover),
                    ),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: accent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: dark ? t.cardElevated : t.card,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                // Долгое нажатие по имени — копирование номера.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => copyPhone(context, phone),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displayName(live.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: t.textPrimary,
                        ),
                      ),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: GestureDetector(
                            onTap: askPhoneMode ? _askClientPhone : null,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (askPhoneMode) ...[
                                  Icon(
                                    Icons.smartphone_rounded,
                                    size: 13,
                                    color: _tint(t),
                                  ),
                                  const SizedBox(width: 4),
                                ] else if (typing) ...[
                                  // Пульсирующая точка: видно, что коллега отвечает
                                  // прямо сейчас.
                                  TweenAnimationBuilder<double>(
                                    key: ValueKey(subtitle),
                                    tween: Tween(begin: 0.35, end: 1),
                                    duration: const Duration(milliseconds: 700),
                                    builder: (_, v, _) => Opacity(
                                      opacity: v,
                                      child: Container(
                                        width: 7,
                                        height: 7,
                                        decoration: BoxDecoration(
                                          color: _tint(t),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Flexible(
                                  child: Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: askPhoneMode || typing
                                          ? _tint(t)
                                          : t.textSecondary,
                                    ),
                                  ),
                                ),
                                if (askPhoneMode) ...[
                                  const SizedBox(width: 3),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 15,
                                    color: _tint(t),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _barIcon(Icons.call_rounded, 'Позвонить', () async {
                await _callPhone(phone);
                if (mounted) await _askCallResult(phone);
              }, tinted: true),
              const SizedBox(width: 6),
              _barIcon(Icons.more_horiz_rounded, 'Ещё', _openChatMenu),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    );
  }

  /// Кнопка шапки: только иконка, подложки нет. Область нажатия всё равно
  /// 40pt — палец попадает.
  Widget _barIcon(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool tinted = false,
    double size = 22,
  }) {
    final t = context.tokens;
    return Tooltip(
      message: tooltip,
      child: PressScale(
        scale: 0.88,
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: size,
            color: tinted ? _tint(t) : t.textPrimary,
          ),
        ),
      ),
    );
  }

  /// Меню чата по «⋯»: крупные плитки действий и отдельная опасная строка.
  ///
  /// Плитки, а не список: до нужного действия один точный тап, а не чтение
  /// подряд шести строк одинакового вида.
  Future<void> _openChatMenu() async {
    final t = context.tokens;
    final live = _live;
    final phone =
        live.phone ?? widget.conversation.phone ?? widget.conversation.id;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheet) => DecoratedBox(
        // Лист во всю ширину, скругление только сверху — без внешних полей.
        decoration: ShapeDecoration(
          color: t.card,
          shape: squircleTop(AppRadius.xl),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 5,
                decoration: ShapeDecoration(
                  color: t.separator,
                  shape: squircle(3),
                ),
              ),
              // Кто перед нами — чтобы не промахнуться чатом.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: ShapeDecoration(
                        color: t.fill,
                        shape: const CircleBorder(),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.asset(flagAsset(phone), fit: BoxFit.cover),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayName(live.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: t.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            _isTelegram ? 'Telegram' : 'WhatsApp',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: t.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Плитки действий: два столбца, крупная цель для пальца.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    _menuTile(
                      sheet,
                      'lead',
                      Iconsax.flash_1,
                      'Лид',
                      const Color(0xFF0E8F82),
                    ),
                    const SizedBox(width: 10),
                    _menuTile(
                      sheet,
                      'massage',
                      Iconsax.health,
                      'Массаж',
                      const Color(0xFFC08401),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    _menuTile(
                      sheet,
                      'vip',
                      Iconsax.crown_1,
                      'Сделать VIP',
                      const Color(0xFFD11E31),
                    ),
                    const SizedBox(width: 10),
                    _menuTile(
                      sheet,
                      'copy',
                      Iconsax.copy,
                      'Копировать номер',
                      t.textSecondary,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Divider(height: 0.5, thickness: 0.5, color: t.separator),
              // Раздел чата: приём / обучение / БАДы — куда чат попадает в
              // списке. Перенос руками, когда автоопределение промахнулось.
              PressScale(
                scale: 0.99,
                onTap: () => Navigator.pop(sheet, 'topic'),
                child: SizedBox(
                  height: 54,
                  child: Row(
                    children: [
                      const SizedBox(width: 18),
                      Icon(Iconsax.folder_2, size: 20, color: t.textSecondary),
                      const SizedBox(width: 12),
                      Text(
                        'Раздел чата',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          color: t.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _topicLabel(live.topic),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: t.textSecondary,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: t.textTertiary,
                      ),
                      const SizedBox(width: 14),
                    ],
                  ),
                ),
              ),
              Divider(height: 0.5, thickness: 0.5, color: t.separator),
              // Блокировка — отдельно от обычных действий, чтобы не задеть.
              PressScale(
                scale: 0.99,
                onTap: () => Navigator.pop(sheet, 'block'),
                child: SizedBox(
                  height: 54,
                  child: Row(
                    children: [
                      const SizedBox(width: 18),
                      Icon(
                        _blocked
                            ? Icons.lock_open_rounded
                            : Icons.block_rounded,
                        size: 20,
                        color: _blocked ? t.success : t.danger,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _blocked
                            ? 'Разблокировать контакта'
                            : 'Заблокировать контакта',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          color: _blocked ? t.success : t.danger,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'lead':
        LeadSheet.show(
          context,
          name: _cardPrefill().name,
          phone: _cardPrefill().phone,
        );
      case 'massage':
        MassageSheet.show(
          context,
          name: _cardPrefill().name,
          phone: _cardPrefill().phone,
        );
      case 'vip':
        VipClientSheet.show(
          context,
          name: _cardPrefill().name,
          phone: _cardPrefill().phone,
        );
      case 'copy':
        copyPhone(context, phone);
      case 'topic':
        await _pickTopic();
      case 'block':
        await _toggleBlock();
    }
  }

  static String _topicLabel(String? topic) => switch (topic) {
    'training' => 'Обучение',
    'supplements' => 'БАДы',
    _ => 'Приём',
  };

  /// Выбор раздела: куда чат попадает в списке (приём / обучение / БАДы).
  Future<void> _pickTopic() async {
    final t = context.tokens;
    final current = _live.topic;
    final options = <(String?, String, IconData, Color)>[
      (null, 'Приём', Iconsax.health, kTealDeep),
      ('training', 'Обучение', Icons.school_rounded, const Color(0xFFC26A00)),
      (
        'supplements',
        'БАДы',
        Icons.medication_rounded,
        const Color(0xFF7233A8),
      ),
    ];
    final picked = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheet) => DecoratedBox(
        decoration: ShapeDecoration(
          color: t.card,
          shape: squircleTop(AppRadius.xl),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 5,
                decoration: ShapeDecoration(
                  color: t.separator,
                  shape: squircle(3),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Раздел чата',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: t.textPrimary,
                    ),
                  ),
                ),
              ),
              for (final (value, label, icon, color) in options)
                PressScale(
                  scale: 0.99,
                  // null — валидный выбор («Приём»), поэтому оборачиваем в список.
                  onTap: () => Navigator.pop(sheet, [value]),
                  child: SizedBox(
                    height: 54,
                    child: Row(
                      children: [
                        const SizedBox(width: 18),
                        Container(
                          width: 34,
                          height: 34,
                          decoration: ShapeDecoration(
                            color: color.withValues(alpha: 0.14),
                            shape: squircle(12),
                          ),
                          child: Icon(icon, size: 18, color: color),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: t.textPrimary,
                          ),
                        ),
                        const Spacer(),
                        if ((current == value) ||
                            (value == null &&
                                current != 'training' &&
                                current != 'supplements'))
                          Icon(Icons.check_rounded, size: 20, color: t.success),
                        const SizedBox(width: 18),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked is! List<String?> || !mounted) return;
    final value = picked.first;
    try {
      await ref
          .read(firestoreChatRepositoryProvider)
          .setTopic(widget.conversation.id, value);
      if (!mounted) return;
      Haptics.success();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Чат перенесён в раздел «${_topicLabel(value)}»'),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не получилось: $e')));
      }
    }
  }

  /// Плитка меню: иконка в цветном сквиркле и подпись под ней.
  Widget _menuTile(
    BuildContext sheet,
    String value,
    IconData icon,
    String label,
    Color color,
  ) {
    final t = context.tokens;
    return Expanded(
      child: PressScale(
        scale: 0.96,
        onTap: () => Navigator.pop(sheet, value),
        child: Container(
          height: 92,
          decoration: ShapeDecoration(
            color: t.fill,
            shape: squircle(AppRadius.sm),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: ShapeDecoration(
                  color: color.withValues(alpha: 0.14),
                  shape: squircle(13),
                ),
                child: Icon(icon, size: 19, color: color),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _saveDraft() {
    if (!mounted) return;
    _drafts.set(widget.conversation.id, _input.text);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

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
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.25 : 0.06),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: dark ? Colors.white70 : const Color(0xFF5C736C),
          ),
        ),
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
    // Список берём из поля: _bubble вызывается из itemBuilder, подписка
    // оттуда заставляет переписку пересобираться и портит прокрутку.
    final me = ref.read(appConfigProvider).userId;
    var name = '';
    for (final u in _managers) {
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
    final time = m.createdAt != null
        ? DateFormat('HH:mm').format(m.createdAt!)
        : '';
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                answered ? Iconsax.call_calling : Iconsax.call_slash,
                size: 15,
                color: color,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  '${answered ? 'Звонок' : 'Звонок без ответа'}'
                  '${who.isEmpty ? '' : ' · $who'}'
                  '${time.isEmpty ? '' : ' · $time'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Экономный режим отрисовки списка сообщений (Android): без размытых теней
  /// под каждым пузырём. На iPhone внешний вид не меняется.
  static final bool _cheapPaint = Platform.isAndroid;

  /// Пузырь сообщения. Силуэт один для всех типов — сквиркл с «прижатым»
  /// углом со стороны отправителя; различается начинка: текст, фото, видео,
  /// голосовое, файл.
  /// Сколько уже ждём первый снимок переписки (для журнала).
  DateTime? _loadStartedAt;
  Timer? _loadWatch;

  /// Сколько раз уже перезапускали подписку на этом экране.
  int _loadRetries = 0;

  /// Три авто-перезапуска не помогли: крутилку сменяем кнопкой «Повторить».
  bool _loadGaveUp = false;

  /// Экран загрузки переписки.
  ///
  /// Если снимок не пришёл за 4 секунды — САМИ пересоздаём подписку. Это ровно
  /// то, что менеджеры делали руками: выходили из чата и заходили снова.
  /// Подписка Firestore на Android иногда не оживает после сна приложения, и
  /// экран оставался с крутилкой навсегда.
  Widget _loadingMessages() {
    if (_loadGaveUp) {
      // Не молчаливая вечная крутилка, а честная кнопка — как при ошибке.
      return _loadFailed(
        'Сервер не ответил. Проверьте интернет и попробуйте ещё раз.',
      );
    }
    _loadStartedAt ??= DateTime.now();
    _loadWatch ??= Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      _loadWatch = null;
      if (_loadRetries >= 3) {
        DiagService.instance.log(
          'CHAT не открылась после 3 перезапусков ${widget.conversation.id}',
        );
        setState(() => _loadGaveUp = true);
        return;
      }
      _loadRetries++;
      DiagService.instance.log(
        'CHAT перезапуск подписки #$_loadRetries ${widget.conversation.id}',
      );
      ref.invalidate(firebaseMessagesProvider(widget.conversation.id));
    });
    // Не крутилка по центру пустого экрана (менеджеры читали её как
    // «приложение зависло»), а заготовка переписки: пузыри на своих местах.
    return const _ChatSkeleton();
  }

  /// Переписка не загрузилась: показываем причину и кнопку «Повторить»,
  /// а не бесконечную крутилку.
  Widget _loadFailed(String error) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 34, color: t.textTertiary),
            const SizedBox(height: 12),
            Text(
              'Переписка не загрузилась',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: t.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: t.textSecondary),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Повторить',
              expand: false,
              onPressed: () {
                _loadStartedAt = null;
                _loadRetries = 0;
                _loadGaveUp = false;
                _loadWatch?.cancel();
                _loadWatch = null;
                ref.invalidate(
                  firebaseMessagesProvider(widget.conversation.id),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Готовые пузыри по id сообщения.
  ///
  /// Список сообщений присылает новый снимок на КАЖДОЕ изменение: галочка
  /// «доставлено», статус очереди, чужое «печатает». Без кэша при этом заново
  /// собирались все видимые пузыри — с текстом, волной голосового и тенями,
  /// отсюда подвисания в активной переписке. Пузырь пересобирается, только
  /// если у самого сообщения что-то изменилось.
  final Map<String, ({String sig, Widget view})> _bubbleCache = {};

  /// Сообщения — одна «серия»: одна сторона, оба обычные (не звонок-заметка)
  /// и между ними меньше 5 минут. Серия рисуется единым блоком: хвостик у
  /// последнего, плотные зазоры внутри.
  static bool _sameBubbleGroup(FsMessage a, FsMessage b) =>
      a.isOutbound == b.isOutbound &&
      a.type != 'call' &&
      b.type != 'call' &&
      !a.isDeleted &&
      !b.isDeleted &&
      a.createdAt != null &&
      b.createdAt != null &&
      b.createdAt!.difference(a.createdAt!).inMinutes.abs() < 5;

  Widget _cachedBubble(FsMessage m, bool dark,
      {required bool first, required bool tail}) {
    final sig = [
      m.text,
      m.type,
      m.status,
      m.queueReason,
      m.statusError,
      m.media,
      m.fileName,
      m.replyToText,
      m.authorId,
      m.authorName,
      m.isDeleted,
      m.isEdited,
      m.textVaried,
      m.isBroadcast,
      m.createdAt?.millisecondsSinceEpoch,
      dark,
      first,
      tail,
      _managers.length,
    ].join('|');
    final hit = _bubbleCache[m.id];
    if (hit != null && hit.sig == sig) return hit.view;
    final view = _bubble(m, dark, first: first, tail: tail);
    // Держим только то, что реально листают: чат отдаёт 100 сообщений.
    if (_bubbleCache.length > 150) _bubbleCache.clear();
    _bubbleCache[m.id] = (sig: sig, view: view);
    return view;
  }

  /// Пузырь на своём месте в переписке: выравнивание, свайп-ответ, долгое
  /// нажатие. Сама «начинка» — в [_bubbleBody], её же показывает меню.
  Widget _bubble(FsMessage m, bool dark, {bool first = true, bool tail = true}) {
    if (m.type == 'call') return _callNote(m, dark);
    final out = m.isOutbound;
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      // Свайп по пузырю — ответить, как в WhatsApp: быстрее, чем долгое
      // нажатие и меню.
      child: _SwipeToReply(
        enabled: !m.isDeleted && !m.id.startsWith('local_'),
        onReply: () => setState(() => _replyTo = m),
        child: Builder(
          // Отдельный context нужен, чтобы узнать, где пузырь на экране:
          // меню всплывает рядом с ним, а не по центру.
          builder: (ctx) => GestureDetector(
            onLongPress: () {
              final box = ctx.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              _showMessageActions(m, box.localToGlobal(Offset.zero) & box.size);
            },
            child: _bubbleBody(m, dark, first: first, tail: tail),
          ),
        ),
      ),
    );
  }

  /// Начинка пузыря без выравнивания и жестов. [first]/[tail] — положение в
  /// серии подряд идущих сообщений одной стороны: у первого полный верхний
  /// угол, хвостик только у последнего, внутри серии углы приспущены.
  Widget _bubbleBody(FsMessage m, bool dark, {bool first = true, bool tail = true}) {
    if (m.type == 'call') return _callNote(m, dark);
    final t = context.tokens;
    final out = m.isOutbound;
    final deleted = m.isDeleted;
    final hasMedia = !deleted && m.media != null && m.media!.isNotEmpty;
    final isPhoto = hasMedia && m.type == 'image';
    final isVideo = hasMedia && m.type == 'video';
    final isAudio = hasMedia && m.type == 'audio';
    final isFile = hasMedia && !isPhoto && !isVideo && !isAudio;
    // Вложение ещё грузится: в пузыре лежит путь к файлу на устройстве.
    final local = hasMedia && !m.media!.startsWith('http');
    final hasText = !deleted && m.text != null && m.text!.isNotEmpty;
    final body = deleted
        ? 'Сообщение удалено'
        : (hasText
              ? m.text!
              : (!hasMedia && m.type != 'text' ? '[${m.type}]' : ''));
    final hasReply =
        !deleted && m.replyToText != null && m.replyToText!.isNotEmpty;

    // Фото/видео без подписи: пузырь = сама картинка, время ложится поверх.
    final metaOnMedia = (isPhoto || isVideo) && body.isEmpty && !hasReply;
    // Остальное без подписи (голосовое, файл): время строкой под вложением.
    final metaBelow = body.isEmpty && !metaOnMedia;
    final meta = _meta(m, onGradient: out && !deleted, onScrim: metaOnMedia);

    const corner = 20.0;
    const mid = 8.0; // приспущенный угол внутри серии
    const tailR = 6.0; // угол-«хвостик» у последнего в серии
    const pad = 3.0;
    // Со стороны автора углы зависят от места в серии, противоположная
    // сторона всегда полная: серия читается единой колонкой.
    final ownTop = first ? corner : mid;
    final ownBottom = tail ? tailR : mid;
    final tl = Radius.circular(out ? corner : ownTop);
    final tr = Radius.circular(out ? ownTop : corner);
    final bl = Radius.circular(out ? corner : ownBottom);
    final br = Radius.circular(out ? ownBottom : corner);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.only(topLeft: tl, topRight: tr, bottomLeft: bl, bottomRight: br),
    );
    // Картинка вписана в пузырь: её радиусы меньше внешних ровно на рамку.
    final innerRadius = BorderRadius.only(
      topLeft: Radius.circular(math.max(0, tl.x - pad)),
      topRight: Radius.circular(math.max(0, tr.x - pad)),
      bottomLeft: Radius.circular(math.max(0, bl.x - pad)),
      bottomRight: Radius.circular(math.max(0, br.x - pad)),
    );

    // Фото и видео идут в край пузыря, у остального — обычные поля.
    final edgeToEdge = isPhoto || isVideo;
    final padding = edgeToEdge
        ? const EdgeInsets.all(pad)
        : isAudio
        ? const EdgeInsets.fromLTRB(8, 8, 12, 8)
        : const EdgeInsets.fromLTRB(13, 8, 13, 7);
    // Подпись под фото живёт внутри пузыря, поэтому отступы свои.
    final captionPad = edgeToEdge
        ? const EdgeInsets.fromLTRB(10, 7, 10, 4)
        : EdgeInsets.only(top: hasMedia ? 7 : 0);

    final textStyle = TextStyle(
      fontSize: 15.5,
      height: 1.32,
      letterSpacing: -0.2,
      color: deleted ? t.textTertiary : (out ? Colors.white : t.textPrimary),
      fontStyle: deleted ? FontStyle.italic : null,
    );

    return Container(
      // Внутри серии пузыри стоят плотно, между сериями — воздух: так серия
      // читается одним блоком, а смена собеседника видна сразу.
      margin: EdgeInsets.only(top: first ? 7 : 1.5, bottom: tail ? 2 : 0),
      padding: padding,
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      decoration: ShapeDecoration(
        gradient: out && !deleted ? _grad(t) : null,
        color: deleted
            ? t.fill
            : (out ? null : (dark ? t.cardElevated : t.card)),
        shape: shape,
        // Тени только в светлой теме; у исходящих — свечение акцентом.
        // На Android теней нет совсем: размытая тень под каждым пузырём —
        // самая дорогая часть кадра, а именно на слабых Samsung список
        // начинал дёргаться при скролле.
        shadows: dark || _cheapPaint
            ? const []
            : (out && !deleted
                  ? [
                      BoxShadow(
                        color: _tint(t).withValues(alpha: 0.22),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : t.shadowSoft),
      ),
      child: Column(
        // Мета под медиа прижимается вправо; Align тут нельзя — он
        // растягивал пузырь на всю допустимую ширину.
        crossAxisAlignment: metaBelow
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasReply)
            Padding(
              padding: EdgeInsets.only(
                bottom: 6,
                left: edgeToEdge ? 7 : 0,
                right: edgeToEdge ? 7 : 0,
                top: edgeToEdge ? 7 : 0,
              ),
              child: _replyQuote(m.replyToText!, out),
            ),
          if (isPhoto) _photoBubble(m, innerRadius, metaOnMedia ? meta : null),
          if (isVideo) _videoBubble(m, innerRadius, metaOnMedia ? meta : null),
          // Пока файл грузится, играть нечего — показываем заглушку.
          if (isAudio)
            local
                ? _uploadingAudio(out)
                : _FbVoicePlayer(
                    url: m.media!,
                    onGradient: out,
                    tint: _tint(t),
                    gradient: _grad(t),
                  ),
          if (isFile) _fileBubble(m, out, local: local),
          // Текст и мета в одной строке: мета «дописывается» в конец
          // последней строки, как в мессенджерах — короткие сообщения
          // не растягиваются в два этажа.
          if (body.isNotEmpty)
            Padding(
              padding: captionPad,
              child: _textWithMeta(body, meta, textStyle),
            ),
          if (metaBelow)
            Padding(
              padding: EdgeInsets.only(
                top: 4,
                left: edgeToEdge ? 10 : 0,
                right: edgeToEdge ? 10 : 0,
                bottom: edgeToEdge ? 4 : 0,
              ),
              child: meta,
            ),
        ],
      ),
    );
  }

  /// Текст с «подвёрстанным» временем: невидимая копия меты занимает место в
  /// конце последней строки, настоящая лежит поверх в правом нижнем углу.
  Widget _textWithMeta(String body, Widget meta, TextStyle style) {
    return Stack(
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: body),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Opacity(
                  opacity: 0,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: meta,
                  ),
                ),
              ),
            ],
          ),
          style: style,
        ),
        Positioned(right: 0, bottom: 0, child: meta),
      ],
    );
  }

  /// Время, автор, галочки. onScrim — версия для наложения поверх фото.
  Widget _meta(FsMessage m, {required bool onGradient, required bool onScrim}) {
    final t = context.tokens;
    final deleted = m.isDeleted;
    final out = m.isOutbound;
    final time = m.createdAt != null
        ? DateFormat('HH:mm').format(m.createdAt!)
        : '';
    final c = onGradient || onScrim
        ? Colors.white.withValues(alpha: 0.88)
        : t.textTertiary;
    final author = _authorLabel(m);

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Кто ответил — мелким текстом рядом со временем.
        if (author != null) ...[
          Text(
            author,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: c,
            ),
          ),
          Text(' · ', style: TextStyle(fontSize: 10, color: c)),
        ],
        if (m.isEdited && !deleted) ...[
          Text('изм.', style: TextStyle(fontSize: 10, color: c)),
          const SizedBox(width: 4),
        ],
        // Текст слегка изменён автоматически: этот шаблон уже уходил другим
        // клиентам, одинаковые сообщения = риск бана номера.
        if (m.textVaried && !deleted) ...[
          Tooltip(
            message:
                'Текст немного изменён автоматически: этот шаблон\n'
                'уже отправлялся другим клиентам (защита номера от бана)',
            child: Icon(Icons.auto_fix_high_rounded, size: 11, color: c),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          time,
          style: TextStyle(
            fontSize: 10.5,
            color: c,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (out && !deleted) ...[
          const SizedBox(width: 3),
          // «queued» — придержано лимитом темпа или ждёт ответа клиента
          // (WABA: вне 24 часов свободный текст WhatsApp не пропустит).
          if (m.status == 'queued' || m.status == 'sending')
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule_rounded, size: 12, color: c),
                const SizedBox(width: 3),
                Text(switch (m.status == 'sending' ? 'delay' : m.queueReason) {
                  'window' => 'ждёт ответа клиента',
                  // WhatsApp: «человечная» пауза перед отправкой.
                  'delay' => 'отправляется…',
                  _ => 'в очереди',
                }, style: TextStyle(fontSize: 10, color: c)),
              ],
            )
          else if (m.status == 'error' || m.status == 'expired')
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 12,
                  color: Color(0xFFFFC9C6),
                ),
                const SizedBox(width: 3),
                Text(
                  m.status == 'expired' ? 'не отправлено' : 'не доставлено',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFFFC9C6),
                  ),
                ),
              ],
            )
          else
            Icon(
              m.status == 'read' || m.status == 'delivered'
                  ? Icons.done_all_rounded
                  : Icons.check_rounded,
              size: 13,
              color: m.status == 'read' ? const Color(0xFFBEEFFF) : c,
            ),
        ],
      ],
    );

    if (!onScrim) return row;
    // Поверх фото время нечитаемо без подложки.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: ShapeDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        shape: squircle(11),
      ),
      child: row,
    );
  }

  Widget _replyQuote(String text, bool out) {
    final t = context.tokens;
    final line = out ? Colors.white : _tint(t);
    return Container(
      // Без width: infinity — иначе цитата растягивала пузырь на всю ширину.
      padding: const EdgeInsets.fromLTRB(9, 6, 9, 6),
      decoration: ShapeDecoration(
        color: (out ? Colors.white : _tint(t)).withValues(
          alpha: out ? 0.18 : 0.10,
        ),
        shape: squircle(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 3,
            height: 28,
            decoration: ShapeDecoration(color: line, shape: squircle(2)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.25,
                color: out
                    ? Colors.white.withValues(alpha: 0.92)
                    : t.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Голосовое, которое ещё загружается: та же форма, что у готового, но с
  /// индикатором вместо волны.
  Widget _uploadingAudio(bool out) {
    final t = context.tokens;
    final fg = out ? Colors.white : t.textSecondary;
    return SizedBox(
      width: 226,
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: ShapeDecoration(
              color: out ? Colors.white.withValues(alpha: 0.25) : t.fill,
              shape: const CircleBorder(),
            ),
            alignment: Alignment.center,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: out ? Colors.white : _tint(t),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Бледная волна — та же форма, что у готового голосового, чтобы
          // пузырь не «прыгал», когда загрузка закончится.
          Expanded(
            child: SizedBox(
              height: 30,
              child: CustomPaint(
                painter: _WavePainter(
                  bars: _FbVoicePlayerState.previewBars,
                  progress: 0,
                  active: fg,
                  muted: out
                      ? Colors.white.withValues(alpha: 0.35)
                      : _tint(t).withValues(alpha: 0.22),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Фото: вписано в силуэт пузыря, тап — полноэкранный просмотр с зумом.
  Widget _photoBubble(FsMessage m, BorderRadius radius, Widget? overlayMeta) {
    final url = m.media!;
    // Ещё не загруженное фото показываем прямо с устройства.
    if (!url.startsWith('http')) {
      return ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 262,
                maxHeight: 340,
                minWidth: 168,
                minHeight: 116,
              ),
              child: Image.file(
                File(url),
                fit: BoxFit.cover,
                // Декодируем под размер пузыря: снимок с камеры в полном
                // разрешении съедал десятки мегабайт на слабых Android.
                cacheWidth: 800,
                errorBuilder: (_, _, _) => _photoPlaceholder(spinner: true),
              ),
            ),
            const Positioned(
              right: 8,
              bottom: 8,
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        PageRouteBuilder<void>(
          opaque: false,
          barrierColor: Colors.black,
          pageBuilder: (_, _, _) => PhotoViewerPage(url: url),
          transitionsBuilder: (_, anim, _, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            Hero(
              tag: url,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 262,
                  maxHeight: 340,
                  minWidth: 168,
                  minHeight: 116,
                ),
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  // Декодируем под размер пузыря (≈262pt при 3x), а не в полном
                  // разрешении: иначе каждое фото в переписке держало в памяти
                  // десятки мегабайт и слабые Android начинали лагать.
                  cacheWidth: 800,
                  // Мягкое проявление вместо рывка при первой отрисовке.
                  frameBuilder: (_, child, frame, wasSync) => wasSync
                      ? child
                      : AnimatedOpacity(
                          opacity: frame == null ? 0 : 1,
                          duration: AppDuration.medium,
                          curve: AppCurves.main,
                          child: child,
                        ),
                  loadingBuilder: (c, w, p) =>
                      p == null ? w : _photoPlaceholder(spinner: true),
                  errorBuilder: (_, _, _) =>
                      _photoPlaceholder(spinner: false, broken: true),
                ),
              ),
            ),
            // Скрим под временем, иначе часы теряются на светлом снимке.
            if (overlayMeta != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    height: 54,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.28),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (overlayMeta != null)
              Positioned(right: 8, bottom: 7, child: overlayMeta),
          ],
        ),
      ),
    );
  }

  Widget _photoPlaceholder({required bool spinner, bool broken = false}) {
    final t = context.tokens;
    return Container(
      width: 216,
      height: 152,
      color: t.isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
      alignment: Alignment.center,
      child: broken
          ? Icon(Icons.broken_image_rounded, size: 26, color: t.textTertiary)
          : spinner
          ? SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: t.textTertiary,
              ),
            )
          : Icon(Icons.image_rounded, size: 26, color: t.textTertiary),
    );
  }

  /// Видео: превью кадра у нас нет, поэтому тёмная плитка со стеклянной
  /// кнопкой play. Тап — открыть системным плеером.
  Widget _videoBubble(FsMessage m, BorderRadius radius, Widget? overlayMeta) {
    return PressScale(
      scale: 0.98,
      onTap: () =>
          launchUrl(Uri.parse(m.media!), mode: LaunchMode.externalApplication),
      child: Container(
        width: 244,
        height: 150,
        decoration: ShapeDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2B3542), Color(0xFF141A21)],
          ),
          shape: RoundedSuperellipseBorder(borderRadius: radius),
        ),
        child: Stack(
          children: [
            Center(
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
            Positioned(
              left: 12,
              bottom: 10,
              child: Row(
                children: [
                  const Icon(
                    Icons.videocam_rounded,
                    size: 14,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Видео',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
            if (overlayMeta != null)
              Positioned(right: 10, bottom: 8, child: overlayMeta),
          ],
        ),
      ),
    );
  }

  /// Файл/документ. PDF (чеки) открываем встроенным просмотрщиком — внешний
  /// браузер на Android их просто скачивал.
  Widget _fileBubble(FsMessage m, bool out, {bool local = false}) {
    final t = context.tokens;
    final fileName = (m.fileName ?? '').trim();
    final mime = (m.mediaContentType ?? '').toLowerCase();
    final isPdf =
        mime.contains('pdf') || fileName.toLowerCase().endsWith('.pdf');
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toUpperCase()
        : (isPdf ? 'PDF' : 'ФАЙЛ');
    final icon = isPdf
        ? Icons.picture_as_pdf_rounded
        : mime.startsWith('audio')
        ? Icons.audiotrack_rounded
        : mime.startsWith('image')
        ? Icons.image_rounded
        : Icons.insert_drive_file_rounded;
    final fg = out ? Colors.white : t.textPrimary;
    final sub = out ? Colors.white.withValues(alpha: 0.75) : t.textSecondary;

    return PressScale(
      scale: 0.98,
      onTap: m.media == null || local
          ? null
          : isPdf
          ? () => PdfViewerPage.open(
              context,
              url: m.media!,
              title: fileName.isNotEmpty ? fileName : 'Документ',
            )
          : () => launchUrl(
              Uri.parse(m.media!),
              mode: LaunchMode.externalApplication,
            ),
      child: SizedBox(
        width: 238,
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: ShapeDecoration(
                color: out ? Colors.white.withValues(alpha: 0.22) : null,
                gradient: out ? null : _grad(t),
                shape: squircle(AppRadius.xs + 4),
              ),
              child: Icon(icon, size: 22, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Обрезаем с конца: расширение всё равно видно строкой ниже.
                  Text(
                    fileName.isNotEmpty ? fileName : 'Документ',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      height: 1.2,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    local
                        ? '$ext · отправляется…'
                        : '$ext · ${isPdf ? 'Открыть' : 'Скачать'}',
                    style: TextStyle(fontSize: 11.5, color: sub),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (local)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: sub),
              )
            else
              Icon(
                isPdf
                    ? Icons.chevron_right_rounded
                    : Icons.arrow_downward_rounded,
                size: 19,
                color: sub,
              ),
          ],
        ),
      ),
    );
  }

  Widget _replyBar(bool dark) {
    final m = _replyTo!;
    final preview = m.isDeleted
        ? 'Сообщение удалено'
        : (m.text?.isNotEmpty == true ? m.text! : '[${m.type}]');
    return Container(
      color: dark ? const Color(0xFF12191E) : Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
        decoration: BoxDecoration(
          color: AppColors.brand.withValues(alpha: 0.10),
          border: const Border(
            left: BorderSide(color: AppColors.brand, width: 3),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            const Icon(Icons.reply_rounded, size: 16, color: AppColors.brand),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    m.isOutbound ? 'Ваше сообщение' : 'Ответ',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.brand,
                    ),
                  ),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: dark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _replyTo = null),
            ),
          ],
        ),
      ),
    );
  }

  /// Черновик от ИИ: не отправляется сам, менеджер видит его над полем ввода
  /// и решает — отправить как есть, вставить в поле для правки или скрыть.
  Widget _aiSuggestionBar(bool dark, String text) {
    final t = context.tokens;
    const accent = Color(0xFF5A4FCF);
    return Container(
      color: dark ? const Color(0xFF12191E) : Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          border: const Border(left: BorderSide(color: accent, width: 3)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Iconsax.magic_star, size: 15, color: accent),
            const SizedBox(width: 6),
            const Text('Черновик от ИИ',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: accent)),
            const Spacer(),
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                Haptics.tap();
                _repo.clearAiSuggestion(widget.conversation.id).catchError((_) {});
              },
              child: Icon(Icons.close_rounded, size: 17, color: t.textTertiary),
            ),
          ]),
          const SizedBox(height: 4),
          Text(text, style: TextStyle(fontSize: 13.5, height: 1.3, color: t.textPrimary)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: const BorderSide(color: accent),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  Haptics.tap();
                  _input.text = text;
                  _input.selection = TextSelection.fromPosition(TextPosition(offset: text.length));
                  setState(() => _hasText = text.trim().isNotEmpty);
                  _repo.clearAiSuggestion(widget.conversation.id).catchError((_) {});
                },
                child: const Text('Править', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  Haptics.success();
                  _input.text = text;
                  setState(() => _hasText = true);
                  await _repo.clearAiSuggestion(widget.conversation.id).catchError((_) {});
                  await _send();
                },
                child: const Text('Отправить', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _composer(bool dark) {
    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: dark ? t.card : t.card,
        border: Border(top: BorderSide(color: t.separator, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.xs,
            AppSpace.xs,
            AppSpace.xs,
            AppSpace.xs,
          ),
          child: _recording ? _recBar() : _inputBar(dark),
        ),
      ),
    );
  }

  Widget _recBar() {
    final t = context.tokens;
    final m = (_recSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_recSeconds % 60).toString().padLeft(2, '0');
    return Row(
      children: [
        _composerIcon(
          Icons.delete_outline_rounded,
          'Отменить запись',
          _cancelRec,
        ),
        Expanded(
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: ShapeDecoration(color: t.fill, shape: squircle(23)),
            child: Row(
              children: [
                // Пульсирующая точка — видно, что запись идёт.
                TweenAnimationBuilder<double>(
                  key: ValueKey(_recSeconds),
                  tween: Tween(begin: 0.4, end: 1),
                  duration: const Duration(milliseconds: 700),
                  builder: (_, v, _) => Opacity(
                    opacity: v,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: t.danger,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$m:$s',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: t.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'запись…',
                  style: TextStyle(fontSize: 13, color: t.textSecondary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpace.xs),
        PressScale(
          scale: 0.9,
          onTap: _stopRecAndSend,
          child: Container(
            width: 46,
            height: 46,
            decoration: ShapeDecoration(
              gradient: _grad(t),
              shape: const CircleBorder(),
              shadows: _glow(t),
            ),
            child: const Icon(
              Icons.arrow_upward_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openQuickReplies() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheet) =>
          _QuickRepliesSheet(onPick: (text) => Navigator.of(sheet).pop(text)),
    );
    if (picked == null || !mounted) return;
    await _confirmQuickReply(picked);
  }

  /// Показ выбранного шаблона целиком перед отправкой: в поле ввода видно
  /// одну строку, и менеджер отправлял не тот ответ, не заметив подмены.
  Future<void> _confirmQuickReply(String text) async {
    final t = context.tokens;
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: t.card,
            shape: squircleTop(AppRadius.xl),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 5,
                  decoration: ShapeDecoration(
                    color: t.separator,
                    shape: squircle(3),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.md,
                    AppSpace.sm,
                    AppSpace.md,
                    AppSpace.xs,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.bolt_rounded, size: 20, color: t.accentSolid),
                      const SizedBox(width: 6),
                      Text(
                        'Отправить этот ответ?',
                        style: Theme.of(sheet).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                // Текст целиком: длинные шаблоны прокручиваются.
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.md,
                      0,
                      AppSpace.md,
                      AppSpace.sm,
                    ),
                    child: Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 320),
                      padding: const EdgeInsets.all(AppSpace.sm),
                      decoration: ShapeDecoration(
                        color: t.fill,
                        shape: squircle(AppRadius.sm),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          text,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.35,
                            color: t.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.md,
                    0,
                    AppSpace.md,
                    AppSpace.xs,
                  ),
                  child: PrimaryButton(
                    label: 'Отправить',
                    icon: Icons.send_rounded,
                    onPressed: () => Navigator.pop(sheet, 'send'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.md,
                    0,
                    AppSpace.md,
                    AppSpace.xs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _sheetButton(
                          sheet,
                          'Выбрать другой',
                          Icons.list_rounded,
                          'again',
                        ),
                      ),
                      const SizedBox(width: AppSpace.xs),
                      Expanded(
                        child: _sheetButton(
                          sheet,
                          'Изменить',
                          Icons.edit_outlined,
                          'edit',
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.md,
                    0,
                    AppSpace.md,
                    AppSpace.sm,
                  ),
                  child: PressScale(
                    onTap: () => Navigator.pop(sheet, 'cancel'),
                    child: SizedBox(
                      height: 44,
                      width: double.infinity,
                      child: Center(
                        child: Text(
                          'Отмена',
                          style: TextStyle(
                            fontSize: 15,
                            color: t.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'send':
        _input.text = text;
        setState(() => _hasText = true);
        await _send();
      case 'edit':
        _input.text = text;
        _input.selection = TextSelection.fromPosition(
          TextPosition(offset: text.length),
        );
        setState(() => _hasText = text.trim().isNotEmpty);
      case 'again':
        await _openQuickReplies();
    }
  }

  Widget _sheetButton(
    BuildContext sheet,
    String label,
    IconData icon,
    String value,
  ) {
    final t = context.tokens;
    return PressScale(
      onTap: () => Navigator.pop(sheet, value),
      child: Container(
        height: 46,
        decoration: ShapeDecoration(
          color: t.fill,
          shape: squircle(AppRadius.sm),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: t.textPrimary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: t.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Поле ввода. Кнопки вложений и шаблонов живут ВНУТРИ «таблетки», справа —
  /// одна круглая кнопка: стрелка при наборе, микрофон в покое.
  Widget _inputBar(bool dark) {
    final t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 46),
            decoration: ShapeDecoration(color: t.fill, shape: squircle(23)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _composerIcon(Icons.add_rounded, 'Вложение', _pickAndSend),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      cursorColor: _tint(t),
                      textCapitalization: TextCapitalization.sentences,
                      style: Theme.of(context).textTheme.bodyLarge,
                      decoration: InputDecoration(
                        hintText: 'Сообщение…',
                        hintStyle: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(color: t.textTertiary),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
                _composerIcon(
                  Icons.bolt_rounded,
                  'Быстрые ответы',
                  _openQuickReplies,
                  accent: true,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpace.xs),
        PressScale(
          scale: 0.9,
          onTap: _hasText ? _send : _startRec,
          child: Container(
            width: 46,
            height: 46,
            decoration: ShapeDecoration(
              gradient: _grad(t),
              shape: const CircleBorder(),
              shadows: _glow(t),
            ),
            child: AnimatedSwitcher(
              duration: AppDuration.fast,
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                _hasText ? Icons.arrow_upward_rounded : Icons.mic_rounded,
                key: ValueKey(_hasText),
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _composerIcon(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool accent = false,
  }) {
    final t = context.tokens;
    return Tooltip(
      message: tooltip,
      child: PressScale(
        scale: 0.88,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 46,
          child: Icon(
            icon,
            size: 23,
            color: accent ? _tint(t) : t.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Меню действий над сообщением: затемнение, пузырь на своём месте и
/// компактная карточка рядом — как в современных мессенджерах.
///
/// Карточка встаёт снизу от пузыря, если внизу есть место, иначе сверху, и
/// прижимается к той же стороне, что и сообщение.
class _MessageMenu extends StatefulWidget {
  const _MessageMenu({
    required this.anchor,
    required this.bubble,
    required this.actions,
    required this.alignRight,
  });

  /// Где пузырь на экране.
  final Rect anchor;
  final Widget bubble;
  final bool alignRight;

  /// (иконка, подпись, разрушающее ли действие, что делать)
  final List<(IconData, String, bool, VoidCallback)> actions;

  @override
  State<_MessageMenu> createState() => _MessageMenuState();
}

class _MessageMenuState extends State<_MessageMenu>
    with SingleTickerProviderStateMixin {
  static const _cardWidth = 236.0;
  static const _rowHeight = 46.0;
  static const _gap = 8.0;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 130),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _close([VoidCallback? action]) async {
    await _c.reverse();
    if (!mounted) return;
    Navigator.of(context).pop();
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final a = widget.anchor;
    final cardHeight = widget.actions.length * _rowHeight + 8;

    // Снизу есть место — меню под сообщением, иначе над ним.
    final below = a.bottom + _gap + cardHeight < size.height - safe.bottom - 12;
    final top = below ? a.bottom + _gap : a.top - _gap - cardHeight;
    final left = widget.alignRight
        ? (a.right - _cardWidth).clamp(12.0, size.width - _cardWidth - 12)
        : a.left.clamp(12.0, size.width - _cardWidth - 12);

    final fade = CurvedAnimation(parent: _c, curve: AppCurves.main);
    // Material обязателен: без него Flutter рисует весь текст жёлтым двойным
    // подчёркиванием («нет Material-предка»). Прозрачный — фон рисуем сами.
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Затемнение: тап мимо — закрыть.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: FadeTransition(
                opacity: fade,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: t.isDark ? 0.55 : 0.32),
                ),
              ),
            ),
          ),
          // Пузырь стоит РОВНО на своём месте и не масштабируется: любое
          // масштабирование текста заставляет глифы пересобираться, буквы едут
          // на доли пикселя, и появление меню читается как рывок.
          Positioned(
            left: a.left,
            top: a.top,
            width: a.width,
            child: IgnorePointer(child: RepaintBoundary(child: widget.bubble)),
          ),
          Positioned(
            left: left.toDouble(),
            top: top
                .clamp(safe.top + 8, size.height - safe.bottom - cardHeight - 8)
                .toDouble(),
            width: _cardWidth,
            // Карточка не масштабируется, а мягко выезжает со стороны сообщения:
            // сдвиг слоя не трогает раскладку текста, поэтому идёт гладко.
            child: FadeTransition(
              opacity: fade,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: Offset(0, below ? -0.08 : 0.08),
                  end: Offset.zero,
                ).animate(fade),
                child: RepaintBoundary(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: t.isDark ? t.cardElevated : t.card,
                      shape: squircle(AppRadius.sm),
                      shadows: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (icon, label, danger, action)
                              in widget.actions)
                            PressScale(
                              scale: 0.97,
                              onTap: () => _close(action),
                              child: SizedBox(
                                height: _rowHeight,
                                child: Row(
                                  children: [
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Text(
                                        label,
                                        style: TextStyle(
                                          fontSize: 15.5,
                                          fontWeight: FontWeight.w500,
                                          color: danger
                                              ? t.danger
                                              : t.textPrimary,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      icon,
                                      size: 19,
                                      color: danger
                                          ? t.danger
                                          : t.textSecondary,
                                    ),
                                    const SizedBox(width: 14),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Свайп вправо по сообщению — ответить на него.
///
/// Пузырь едет за пальцем, слева проявляется стрелка; после порога — короткий
/// тактильный щелчок, и дальше пузырь возвращается сам. Порог небольшой:
/// длинный свайп в списке сообщений неудобен одной рукой.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onReply;
  final bool enabled;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const _trigger = 56.0;

  /// Смещение живёт в ValueNotifier, а не в setState: перестраивается только
  /// обёртка с трансформом, сам пузырь (текст, волна голосового, картинка)
  /// строится один раз. Иначе каждое движение пальца пересобирало сообщение
  /// целиком — на длинных чатах свайп заметно тормозил.
  final ValueNotifier<double> _dx = ValueNotifier<double>(0);

  /// Контроллер возврата создаётся при ПЕРВОМ свайпе: на каждое сообщение в
  /// списке свой ticker — лишняя работа на каждом кадре. Nullable, а не late:
  /// ленивое поле рождалось прямо в dispose и роняло debug-сборку.
  AnimationController? _back;

  double _from = 0;
  bool _fired = false;

  AnimationController _ensureBack() {
    return _back ??=
        AnimationController(
          vsync: this,
          duration: AppDuration.fast,
        )..addListener(
          () =>
              _dx.value = _from * (1 - AppCurves.main.transform(_back!.value)),
        );
  }

  @override
  void dispose() {
    _back?.dispose();
    _dx.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    if (!widget.enabled) return;
    if (_back?.isAnimating ?? false) _back!.stop();
    // Тянем только вправо; дальше порога — с сопротивлением.
    final raw = _dx.value + d.delta.dx;
    final next = raw <= _trigger
        ? raw.clamp(0.0, _trigger)
        : _trigger + (raw - _trigger) * 0.35;
    if (!_fired && next >= _trigger) {
      _fired = true;
      Haptics.select();
    }
    _dx.value = next.clamp(0.0, 90.0);
  }

  void _end([DragEndDetails? _]) {
    final fire = _fired;
    _fired = false;
    _from = _dx.value;
    if (_from > 0) _ensureBack().forward(from: 0);
    if (fire) widget.onReply();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: ValueListenableBuilder<double>(
        valueListenable: _dx,
        // child строится один раз и переиспользуется на каждом кадре.
        child: RepaintBoundary(child: widget.child),
        builder: (_, dx, child) => Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (dx > 4)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Opacity(
                  opacity: (dx / _trigger).clamp(0.0, 1.0),
                  child: Icon(
                    Icons.reply_rounded,
                    size: 20,
                    color: t.accentSolid,
                  ),
                ),
              ),
            Transform.translate(offset: Offset(dx, 0), child: child),
          ],
        ),
      ),
    );
  }
}

/// Отправленное сообщение, ещё не подтверждённое сервером: показывается в
/// чате сразу, чтобы менеджер не ждал ни загрузку файла, ни ответ функции.

/// Заготовка переписки на время загрузки.
///
/// Крутилка по центру пустого экрана читалась менеджерами как «приложение
/// зависло». Серые пузыри на своих местах выглядят как чат, который вот-вот
/// проявится, — ощущение загрузки вместо подвисания. Один общий контроллер
/// пульсации на все пузыри: десяток отдельных анимаций на слабом Android
/// сам стал бы источником лагов.
class _ChatSkeleton extends StatefulWidget {
  const _ChatSkeleton();

  @override
  State<_ChatSkeleton> createState() => _ChatSkeletonState();
}

class _ChatSkeletonState extends State<_ChatSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  // (исходящий?, доля ширины экрана, высота) — рисунок как у живой переписки.
  static const _rows = <(bool, double, double)>[
    (false, 0.52, 44),
    (false, 0.36, 34),
    (true, 0.60, 50),
    (true, 0.30, 34),
    (false, 0.68, 60),
    (true, 0.44, 44),
    (false, 0.34, 34),
    (true, 0.56, 50),
    (false, 0.47, 44),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final w = MediaQuery.sizeOf(context).width;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, _) {
          // Полупрозрачный цвет карточки виден и на светлых, и на тёмных обоях.
          final fill = t.card.withValues(alpha: 0.45 + 0.25 * _pulse.value);
          return ListView(
            // reverse: пузыри прижаты к низу, как в настоящем чате.
            reverse: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            children: [
              for (final (out, frac, h) in _rows.reversed)
                Align(
                  alignment: out ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: w * frac,
                    height: h,
                    margin: const EdgeInsets.only(top: 6),
                    decoration: ShapeDecoration(
                      shape: squircle(18),
                      color: fill,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Голосовое: волна вместо полоски, перемотка тапом и протяжкой, переключение
/// скорости. Аудио тянем по ссылке лениво — грузить все голосовые чата при
/// открытии переписки нельзя.
class _FbVoicePlayer extends StatefulWidget {
  const _FbVoicePlayer({
    required this.url,
    required this.onGradient,
    required this.tint,
    required this.gradient,
  });
  final String url;
  final bool onGradient;

  /// Цвет мессенджера: в WhatsApp плеер зелёный, в Telegram — синий.
  final Color tint;
  final LinearGradient gradient;

  @override
  State<_FbVoicePlayer> createState() => _FbVoicePlayerState();
}

class _FbVoicePlayerState extends State<_FbVoicePlayer> {
  static const _barCount = 26;

  /// Звуком владеет НЕ пузырь, а общий [VoiceController]: пузырь может
  /// умереть при прокрутке или пересборке списка — голосовое продолжает
  /// играть, а вернувшийся на экран пузырь снова показывает живой прогресс.
  VoiceController get _vc => VoiceController.I;

  /// Настоящих амплитуд у нас нет (Telegram их не отдаёт), поэтому рисуем
  /// стабильную «волну» из хеша ссылки: у одного сообщения она всегда одна.
  late final List<double> _bars = _waveform(widget.url);

  /// Волна для ещё не загруженного голосового (форма пузыря не меняется,
  /// когда отправка завершится).
  static final List<double> previewBars = _waveform('preview');

  static List<double> _waveform(String seed) {
    var h = 7;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final rnd = math.Random(h);
    return List<double>.generate(_barCount, (i) {
      // Огибающая, чтобы волна не выглядела ровным забором.
      final env = 0.55 + 0.45 * math.sin((i + 1) / (_barCount + 1) * math.pi);
      return (0.25 + rnd.nextDouble() * 0.75) * env;
    });
  }

  @override
  void initState() {
    super.initState();
    _vc.addListener(_onController);
  }

  @override
  void dispose() {
    _vc.removeListener(_onController);
    super.dispose();
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    final ok = await _vc.toggle(widget.url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось воспроизвести')),
      );
    }
  }

  Future<void> _seekTo(double fraction) => _vc.seekTo(widget.url, fraction);

  Future<void> _cycleSpeed() => _vc.cycleSpeed();

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final og = widget.onGradient;
    final player = _vc.playerOf(widget.url);
    final playing = _vc.isCurrent(widget.url) && _vc.playing;
    final loading = _vc.isCurrent(widget.url) && _vc.loading;
    final speed = _vc.speed;
    final circleFg = og ? widget.tint : Colors.white;
    final active = og ? Colors.white : widget.tint;
    final muted = og
        ? Colors.white.withValues(alpha: 0.38)
        : widget.tint.withValues(alpha: 0.28);
    final metaColor = og
        ? Colors.white.withValues(alpha: 0.85)
        : t.textTertiary;

    return SizedBox(
      width: 226,
      child: Row(
        children: [
          PressScale(
            scale: 0.9,
            onTap: _toggle,
            child: Container(
              width: 42,
              height: 42,
              decoration: ShapeDecoration(
                color: og ? Colors.white : null,
                gradient: og ? null : widget.gradient,
                shape: const CircleBorder(),
              ),
              alignment: Alignment.center,
              child: loading
                  ? SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: circleFg,
                      ),
                    )
                  : AnimatedSwitcher(
                      duration: AppDuration.fast,
                      child: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        key: ValueKey(playing),
                        color: circleFg,
                        size: 24,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            // Пока не нажали play, плеера нет — и подписки на позицию тоже.
            child: StreamBuilder<Duration>(
              stream: player?.positionStream,
              builder: (context, snap) {
                final pos = snap.data ?? Duration.zero;
                final dur = player?.duration ?? Duration.zero;
                final progress = dur.inMilliseconds == 0
                    ? 0.0
                    : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LayoutBuilder(
                      builder: (_, c) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) =>
                            _seekTo(d.localPosition.dx / c.maxWidth),
                        onHorizontalDragUpdate: (d) =>
                            _seekTo(d.localPosition.dx / c.maxWidth),
                        child: SizedBox(
                          height: 30,
                          width: c.maxWidth,
                          child: CustomPaint(
                            painter: _WavePainter(
                              bars: _bars,
                              progress: progress,
                              active: active,
                              muted: muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        // Длительность известна только после загрузки файла —
                        // до первого запуска показываем подпись, а не «0:00».
                        Text(
                          dur == Duration.zero
                              ? 'Голосовое'
                              : _fmt(
                                  pos > Duration.zero || playing ? pos : dur,
                                ),
                          style: TextStyle(
                            fontSize: 11,
                            color: metaColor,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const Spacer(),
                        // Скорость: слушать длинные голосовые на 1× долго.
                        PressScale(
                          scale: 0.92,
                          onTap: _cycleSpeed,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: ShapeDecoration(
                              color: (og ? Colors.white : widget.tint)
                                  .withValues(alpha: og ? 0.22 : 0.10),
                              shape: squircle(8),
                            ),
                            child: Text(
                              '${speed == 1 ? '1' : speed.toString().replaceAll('.0', '')}×',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: og ? Colors.white : widget.tint,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Волна голосового: прослушанная часть — активным цветом, остаток — блёклым.
class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.bars,
    required this.progress,
    required this.active,
    required this.muted,
  });

  final List<double> bars;
  final double progress;
  final Color active;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / bars.length;
    final w = math.min(3.4, step * 0.62);
    final mid = size.height / 2;
    for (var i = 0; i < bars.length; i++) {
      final h = math.max(3.0, bars[i] * size.height);
      final x = i * step + (step - w) / 2;
      final paint = Paint()
        ..color = (i + 0.5) / bars.length <= progress ? active : muted;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, mid - h / 2, w, h),
          Radius.circular(w / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.progress != progress ||
      old.active != active ||
      old.muted != muted ||
      old.bars != bars;
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleC,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Заголовок',
                hintText: 'напр. Приветствие',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: textC,
              minLines: 2,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Основной текст',
                hintText: 'Текст, который вставится в сообщение',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (ok == true && textC.text.trim().isNotEmpty) {
      final svc = ref.read(quickRepliesServiceProvider);
      final title = titleC.text.trim().isEmpty
          ? textC.text.trim()
          : titleC.text.trim();
      try {
        if (existing == null) {
          await svc.add(title: title, text: textC.text.trim());
        } else {
          await svc.update(existing.id, title: title, text: textC.text.trim());
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
        }
      }
    }
    // Как и в диалоге правки: dispose после анимации закрытия диалога.
    Future.delayed(const Duration(milliseconds: 600), () {
      titleC.dispose();
      textC.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
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
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(
                  children: [
                    Icon(Icons.bolt_rounded, color: AppColors.brand),
                    SizedBox(width: 8),
                    Text(
                      'Быстрые ответы',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ref
                    .watch(quickRepliesProvider)
                    .when(
                      loading: () =>
                          const SkeletonList(count: 6, avatar: false),
                      error: (e, _) => Center(child: Text('Ошибка: $e')),
                      data: (items) {
                        if (items.isEmpty) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'Пока нет шаблонов.\nНажмите «Добавить».',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final q = items[i];
                            // Свайп-удаления здесь больше нет: шаблон смахивали
                            // случайно при скролле, и он пропадал молча у всех.
                            // Удаление — только на экране «Быстрые ответы»,
                            // с подтверждением и только у админа.
                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: Material(
                                color: dark
                                    ? const Color(0xFF1B242B)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                clipBehavior: Clip.antiAlias,
                                child: ListTile(
                                  title: Text(
                                    q.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: Text(
                                    q.text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: dark
                                          ? Colors.white60
                                          : Colors.black54,
                                    ),
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 19,
                                    ),
                                    onPressed: () => _openEditor(existing: q),
                                  ),
                                  // Лист закрывает сам onPick (возвращает текст
                                  // вызвавшему) — второй pop закрыл бы чат.
                                  onTap: () => widget.onPick(q.text),
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
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text(
                        'Добавить шаблон',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      onPressed: () => _openEditor(),
                    ),
                  ),
                ),
              ),
            ],
          ),
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

class _PhotoViewerPageState extends State<PhotoViewerPage>
    with SingleTickerProviderStateMixin {
  final _ctrl = TransformationController();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
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
            ..translateByDouble(
              -d.localPosition.dx * 1.5,
              -d.localPosition.dy * 1.5,
              0,
              1,
            )
            ..scaleByDouble(2.5, 2.5, 1, 1));
    _zoomAnim = Matrix4Tween(
      begin: _ctrl.value,
      end: target,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final opacity = (1 - (_dragY.abs() / 400)).clamp(0.35, 1.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: opacity),
      body: Stack(
        children: [
          // Свайп вниз закрывает (только когда не приближено).
          GestureDetector(
            onVerticalDragUpdate: _zoomed
                ? null
                : (d) => setState(() => _dragY += d.delta.dy),
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
                              height: 120,
                              width: 120,
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                      errorBuilder: (_, _, _) => const Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Не удалось загрузить фото',
                          style: TextStyle(color: Colors.white70),
                        ),
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
            child: Row(
              children: [
                _round(
                  Icons.close_rounded,
                  'Закрыть',
                  () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                _round(
                  Icons.open_in_new_rounded,
                  'Открыть в браузере',
                  () => launchUrl(
                    Uri.parse(widget.url),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
