import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../data/presence_service.dart';
import '../data/push_service.dart' show appNavigatorKey;
import '../data/session_service.dart';
import '../state/providers.dart';
// import 'broadcast_screen.dart'; — вернуть вместе с вкладкой «Рассылка»
import 'conversations_screen.dart';
import 'firebase_chats.dart';
import 'leads_screen.dart';
import 'massage_screen.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPresence());
  }

  @override
  void dispose() {
    if (_presenceOn) _presence?.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Нас вытеснил другой менеджер — выходим и показываем окно.
  Future<void> _kickOut(String byName) async {
    if (_kicked || !mounted) return;
    _kicked = true;
    final cfg = ref.read(appConfigProvider);
    if (_presenceOn) {
      _presence?.stop();
      _presenceOn = false;
    }
    try {
      await ref.read(firebaseAuthServiceProvider).signOut();
    } catch (_) {}
    await cfg.logout();

    // Диалог показываем через корневой навигатор: MainShell к этому моменту
    // уже заменён экраном входа.
    final nav = appNavigatorKey.currentState;
    if (nav == null || !nav.mounted) return;
    await showDialog<void>(
      context: nav.context,
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

  void _startPresence() {
    if (!mounted) return;
    final cfg = ref.read(appConfigProvider);
    if (!cfg.isFirebase || cfg.userId == null) return;
    _presence = ref.read(firebasePresenceServiceProvider);
    _presence!.start(cfg.userId!, cfg.userName ?? '');
    _presenceOn = true;
    // Пуши: регистрация FCM-токена + обработка тапа по уведомлению.
    ref.read(pushServiceProvider).register(cfg.userId!);
    _session = ref.read(sessionServiceProvider);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cfg = ref.read(appConfigProvider);
    if (!cfg.isFirebase) return;
    final presence = ref.read(firebasePresenceServiceProvider);
    if (state == AppLifecycleState.resumed) {
      _startPresence();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
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
    final singleSession = ref.watch(singleSessionEnabledProvider).value ?? true;
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
      const MassageScreen(),
      const VipClientsScreen(),
      // Рассылка временно скрыта (вернуть: if (isAdmin) const BroadcastScreen()).
      const SettingsScreen(),
    ];
    final items = <(IconData, String)>[
      (Iconsax.message, 'Чаты'),
      (Iconsax.flash_1, 'Лиды'),
      (Iconsax.health, 'Массаж'),
      (Iconsax.crown_1, 'VIP'),
      // if (isAdmin) (Iconsax.send_2, 'Рассылка'),
      (Iconsax.setting_2, 'Настройки'),
    ];
    final index = _index.clamp(0, pages.length - 1);
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: _SoftNavBar(items: items, index: index, onTap: (i) => setState(() => _index = i)),
    );
  }
}

/// «Мягкий» нижний навбар: скруглённый верх, пилюля-подсветка активной вкладки,
/// Iconsax-иконки. Отступ снизу берётся из безопасной зоны — работает и с
/// iOS home-индикатором, и с Android gesture/кнопочной навигацией.
class _SoftNavBar extends StatelessWidget {
  const _SoftNavBar({required this.items, required this.index, required this.onTap});
  final List<(IconData, String)> items;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF141E22) : Colors.white;
    final inactive = dark ? const Color(0xFF7E938D) : kSub;
    // Нижний системный отступ (home-индикатор / gesture bar); если его нет
    // (Android с кнопками) — даём собственные 10.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.07),
            blurRadius: 22,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(4, 9, 4, bottomInset > 0 ? bottomInset : 10),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavItem(
                    icon: items[i].$1,
                    label: items[i].$2,
                    selected: i == index,
                    inactive: inactive,
                    compact: items.length > 5, // 6 вкладок — ужимаем пилюлю
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.inactive,
    required this.onTap,
    this.compact = false,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final Color inactive;
  final VoidCallback onTap;

  /// Плотный режим (6 вкладок): уже пилюля и мельче подпись.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = selected ? kTealDeep : inactive;
    return InkResponse(
      onTap: onTap,
      radius: 40,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 17, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? kTeal.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Icon(icon, size: compact ? 21 : 22, color: color),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label,
                maxLines: 1,
                style: TextStyle(
                    fontSize: compact ? 9.5 : 10.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: color)),
          ),
        ],
      ),
    );
  }
}
