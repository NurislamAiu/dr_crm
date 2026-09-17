import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/diag_service.dart';
import '../data/presence_service.dart';
import '../data/push_service.dart' show appNavigatorKey;
import '../data/session_service.dart';
import '../design/design.dart';
import '../state/providers.dart';
import 'contest_screen.dart';
import 'conversations_screen.dart';
import 'firebase_chats.dart';
import 'leads_screen.dart';
import 'session_wait_screen.dart';
import 'settings_screen.dart';
import 'soft_ui.dart';
import 'vip_clients_screen.dart';

/// Корневой каркас с нижней навигацией: Чаты · Лиды · VIP · Рассылка · Настройки.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _presenceOn = false;

  // Кэш сервисов: в dispose пользоваться ref уже нельзя.
  FirebasePresenceService? _presence;
  SessionService? _session;
  bool _kicked = false; // чтобы не показать окно дважды

  /// Восстановление уже выполнялось для ЭТОГО входа (НЕ static: правило
  /// «один менеджер в системе» означает, что за один запуск приложения
  /// вход/выход могут смениться несколько раз — у каждого нового менеджера
  /// должна быть своя попытка восстановить свой чат, static-флаг это
  /// глушил после первого же логина в процессе).
  bool _chatRestoreDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startPresence();
      _restoreOpenChat();
    });
  }

  /// Открыть чат, в котором менеджера застала гибель процесса.
  ///
  /// Android в фоне убивает приложение почти сразу — при возврате оно
  /// запускается заново со списка чатов, и открытая переписка «закрывалась».
  /// Экран чата держит отметку openChatId (снимается при штатном выходе из
  /// чата) — если она осталась, значит процесс погиб с открытым чатом, и мы
  /// возвращаем менеджера на место.
  Future<void> _restoreOpenChat() async {
    if (_chatRestoreDone) return;
    _chatRestoreDone = true;
    final cfg = ref.read(appConfigProvider);
    if (!cfg.isFirebase || cfg.userId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('openChatId') ?? '';
      final at = prefs.getInt('openChatAt') ?? 0;
      final owner = prefs.getString('openChatUid') ?? '';
      if (id.isEmpty) return;
      // Устройство общее между менеджерами (правило «один менеджер в
      // системе») — чужую открытую переписку не показываем.
      if (owner != cfg.userId) {
        await prefs.remove('openChatId');
        return;
      }
      // Свежесть: чат, брошенный полдня назад, открывать заново не надо.
      if (DateTime.now().millisecondsSinceEpoch - at > 6 * 3600 * 1000) {
        await prefs.remove('openChatId');
        return;
      }
      final conv = await ref.read(firestoreChatRepositoryProvider).watchConversation(id).first;
      if (conv == null || !mounted) return;
      final nav = appNavigatorKey.currentState;
      if (nav == null || !nav.mounted) return;
      await nav.push(MaterialPageRoute(builder: (_) => FirebaseChatScreen(conversation: conv)));
    } catch (_) {
      // Не вышло восстановить — остаёмся на списке, это не ошибка.
    }
  }

  @override
  void dispose() {
    if (_presenceOn) _presence?.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Нас вытеснил другой менеджер. Сначала — зона ожидания на 30 секунд:
  /// если система освободится, работаем дальше без повторного входа.
  Future<void> _kickOut(String byName) async {
    if (_kicked || !mounted) return;
    _kicked = true;

    final nav = appNavigatorKey.currentState;
    if (nav != null && nav.mounted) {
      final freed = await nav.push<bool>(
        MaterialPageRoute(builder: (_) => SessionWaitScreen(byName: byName), fullscreenDialog: true),
      );
      if (freed == true && mounted) {
        // Освободилась — снова занимаем систему за собой.
        final cfg = ref.read(appConfigProvider);
        _kicked = false;
        if (cfg.userId != null) {
          _session ??= ref.read(sessionServiceProvider);
          try {
            await _session!.claim(uid: cfg.userId!, name: cfg.userName ?? '');
          } catch (_) {}
        }
        return;
      }
    }

    final cfg = ref.read(appConfigProvider);
    if (_presenceOn) {
      _presence?.stop();
      _presenceOn = false;
    }
    try {
      await ref.read(firebaseAuthServiceProvider).signOut();
    } catch (_) {}
    // Сначала закрываем всё, что открыто поверх (настройки, чат, аналитика) —
    // иначе экран входа окажется под ними.
    appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    await cfg.logout();

    // Диалог показываем через корневой навигатор: MainShell к этому моменту
    // уже заменён экраном входа.
    final root = appNavigatorKey.currentState;
    if (root == null || !root.mounted) return;
    await showDialog<void>(
      context: root.context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Iconsax.profile_2user, size: 34, color: Color(0xFFC6403C)),
        title: const Text('В систему вошёл другой менеджер', textAlign: TextAlign.center),
        content: Text(
          byName.isEmpty
              ? 'Одновременно работать может только один менеджер. Вы вышли из системы.'
              : 'Сейчас в системе $byName. Одновременно работать может только один менеджер — Вы вышли.',
          textAlign: TextAlign.center,
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kTeal),
            onPressed: () => Navigator.pop(d),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  /// Правило «один менеджер в системе»: занимаем систему за собой, если
  /// правило включено и мы НЕ админ (админ работает параллельно).
  Future<void> _syncSession({required bool enabled, required bool isAdmin}) async {
    final cfg = ref.read(appConfigProvider);
    if (!cfg.isFirebase || cfg.userId == null) return;
    _session ??= ref.read(sessionServiceProvider);
    final svc = _session!;
    if (!enabled || isAdmin) {
      if (svc.hasClaim) await svc.release();
      return;
    }
    if (svc.hasClaim) return;
    await svc.claim(uid: cfg.userId!, name: cfg.userName ?? '');
  }

  bool _pushRegistered = false;

  void _startPresence() {
    if (!mounted) return;
    final cfg = ref.read(appConfigProvider);
    if (!cfg.isFirebase || cfg.userId == null) return;
    // ИДЕМПОТЕНТНО: на Samsung сигнал resumed стреляет СЕРИЯМИ (каждая потеря/
    // возврат фокуса окна, в т.ч. при выезде клавиатуры). Без этой защиты
    // presence перезапускался 6-9 раз В СЕКУНДУ: шторм записей в Firestore,
    // телефон захлёбывался, клавиатура не могла открыться.
    if (_presenceOn) return;
    _presence = ref.read(firebasePresenceServiceProvider);
    // Админ (владелец) в списке «в сети» не светится: заходит проверить
    // работу — и менеджеры сразу видят, что за ними наблюдают. На самих
    // менеджеров это не распространяется, друг друга они видят как раньше.
    final invisible = cfg.role == 'admin' || cfg.role == 'administrator';
    _presence!.start(cfg.userId!, cfg.userName ?? '', hidden: invisible);
    _presenceOn = true;
    // Пуши: регистрация FCM-токена — один раз за запуск приложения.
    if (!_pushRegistered) {
      _pushRegistered = true;
      ref.read(pushServiceProvider).register(cfg.userId!);
    }
    _session = ref.read(sessionServiceProvider);
    // Удалённая диагностика (ошибки/jank/клавиатура) → clientLogs/{uid}.
    DiagService.instance.start(cfg.userId!);
  }

  @override
  void didChangeMetrics() => DiagService.instance.onMetrics();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cfg = ref.read(appConfigProvider);
    if (!cfg.isFirebase) return;
    final presence = ref.read(firebasePresenceServiceProvider);
    if (state == AppLifecycleState.resumed) {
      _startPresence();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // inactive НЕ считаем уходом: он приходит при каждой потере фокуса окна
      // (клавиатура, шторка, диалог) — на Samsung сериями. Раньше пара
      // inactive→resumed устраивала stop/start presence на каждый чих.
      if (_presenceOn) {
        presence.stop();
        _presenceOn = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appConfigProvider);
    // Вкладка «Чаты» зависит от backend: firebase → Firestore-чаты.
    final isFirebase = config.isFirebase;
    // Рассылка — только для админа.
    final isAdmin = config.role == 'admin' || config.role == 'administrator';

    // Правило «один менеджер в системе»: включается админом в настройках,
    // на самого админа не распространяется.
    //
    // Пока настройка ещё не подгрузилась из Firestore (доля секунды на
    // старте приложения), .value равен null — и раньше тут стояло «?? true»,
    // то есть на этот короткий момент правило считалось ВКЛЮЧЕННЫМ, даже
    // если админ его выключил. Этого хватало, чтобы _syncSession занял
    // сессию за собой и вытолкнул остальных менеджеров, прежде чем настоящее
    // (выключенное) значение успевало прийти. Безопасный дефолт на время
    // загрузки — «выключено»: ничего не отнимаем, пока не знаем наверняка.
    final singleSession = ref.watch(singleSessionEnabledProvider).value ?? false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSession(enabled: singleSession, isAdmin: isAdmin);
    });
    ref.listen(activeSessionProvider, (_, next) {
      if (!singleSession || isAdmin) return; // админа не выкидываем
      final active = next.value;
      final mine = _session?.mySessionId;
      if (mine == null || active == null) return;
      if (active.sessionId != mine) _kickOut(active.name);
    });
    final pages = [
      isFirebase ? const FirebaseConversationsScreen() : const ConversationsScreen(),
      const LeadsScreen(),
      // «Массаж» уехал из нижней панели: место занял экран соревнования.
      // Сами записи на массаж никуда не делись — они по-прежнему создаются
      // из карточки клиента и участвуют в расписании.
      const ContestScreen(),
      const VipClientsScreen(),
      const SettingsScreen(),
    ];
    const items = <AppTabItem>[
      AppTabItem(icon: Iconsax.message, label: 'Чаты'),
      AppTabItem(icon: Iconsax.flash_1, label: 'Лиды'),
      AppTabItem(icon: Iconsax.cup, label: 'Конкурс'),
      AppTabItem(icon: Iconsax.crown_1, label: 'VIP'),
      AppTabItem(icon: Iconsax.setting_2, label: 'Настройки'),
    ];
    final index = _index.clamp(0, pages.length - 1);

    // Кнопки «+» рядом с таб-баром нет: на экранах лидов, массажа и VIP
    // своя кнопка создания в шапке, а всплывающая рядом мешала.

    return Scaffold(
      // Контент проезжает под стеклянным баром.
      extendBody: true,
      body: MediaQuery(
        // Экраны, уважающие безопасную зону, сами отступят от бара.
        data: MediaQuery.of(context).copyWith(
          padding: MediaQuery.paddingOf(context).copyWith(
            bottom: MediaQuery.paddingOf(context).bottom + FloatingTabBar.height + AppSpace.sm,
          ),
        ),
        child: IndexedStack(index: index, children: pages),
      ),
      bottomNavigationBar: FloatingTabBar(
        items: items,
        index: index,
        onChanged: (i) => setState(() => _index = i),
      ),
    );
  }
}



