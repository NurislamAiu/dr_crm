import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../state/providers.dart';
import 'analytics_screen.dart';
import 'autoreply_screen.dart';
import 'quick_replies_screen.dart';
import 'firebase_managers_screen.dart';
import 'managers_screen.dart';
import 'soft_ui.dart';
import 'waba_screen.dart';

const _pageBg = Color(0xFFF1F8F6);

/// Настройки — «мягкий» стиль: профиль менеджера в шапке, карточки-разделы.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool get _isAdmin {
    final role = ref.read(appConfigProvider).role;
    return role == 'admin' || role == 'administrator';
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.read(appConfigProvider);
    final name = (config.userName ?? '').trim();
    final initial = name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase();
    final roleLabel = _isAdmin ? 'Администратор' : 'Менеджер';

    return Scaffold(
      backgroundColor: _pageBg,
      body: Column(
        children: [
          SoftHeader(
            color: kTeal,
            colorDeep: kTealDeep,
            title: 'Настройки',
            dateLabel: weekdayDateRu(DateTime.now()),
            actions: const [],
            strip: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: Text(initial,
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: kTealDeep)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name.isEmpty ? 'Менеджер' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
                    const SizedBox(height: 2),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_isAdmin ? Iconsax.shield_tick : Iconsax.user_octagon,
                          size: 13, color: Colors.white.withValues(alpha: 0.85)),
                      const SizedBox(width: 4),
                      Text(roleLabel,
                          style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
                    ]),
                  ]),
                ),
              ]),
            ),
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
                  if (_isAdmin && config.isFirebase)
                    _navCard(
                      icon: Iconsax.chart_2,
                      color: const Color(0xFF5A6ACF),
                      title: 'Аналитика',
                      subtitle: 'Кто в сети и сколько сделал каждый менеджер',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AnalyticsScreen()),
                      ),
                    ),
                  if (_isAdmin)
                    _navCard(
                      icon: Iconsax.profile_2user,
                      color: kTealDeep,
                      title: 'Менеджеры',
                      subtitle: 'Добавить и настроить доступ команды',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => config.isFirebase ? const FirebaseManagersScreen() : const ManagersScreen(),
                        ),
                      ),
                    ),
                  if (_isAdmin && config.isFirebase)
                    _navCard(
                      icon: Iconsax.verify,
                      color: const Color(0xFF1B5BC4),
                      title: 'Канал WhatsApp',
                      subtitle: 'Обычный номер или WABA, шаблоны сообщений',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const WabaScreen()),
                      ),
                    ),
                  if (_isAdmin && config.isFirebase)
                    _navCard(
                      icon: Iconsax.message_time,
                      color: const Color(0xFFB07A10),
                      title: 'Автоответчик',
                      subtitle: 'Автоответ на входящие и пропущенные звонки',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AutoReplyScreen()),
                      ),
                    ),
                  _navCard(
                    icon: Iconsax.flash_1,
                    color: kTealDeep,
                    title: 'Быстрые ответы',
                    subtitle: 'Шаблоны сообщений для кнопки ⚡ в чате',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const QuickRepliesScreen()),
                    ),
                  ),
                  if (config.isFirebase && config.userId != null) _NotifyToggleCard(uid: config.userId!),
                  if (config.isFirebase) const _ChannelCard(),
                  if (_isAdmin && config.isFirebase) const _SingleSessionCard(),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFBEDEC),
                        foregroundColor: const Color(0xFFC6403C),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      ),
                      icon: const Icon(Iconsax.logout, size: 20),
                      label: const Text('Выйти из аккаунта', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      onPressed: () async {
                        if (config.isFirebase) {
                          // Освобождаем систему для следующего менеджера.
                          await ref.read(sessionServiceProvider).release();
                          await ref.read(firebaseAuthServiceProvider).signOut().catchError((_) {});
                        }
                        await config.logout();
                        if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, size: 21, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: kSub)),
                ]),
              ),
              const SizedBox(width: 8),
              const Icon(Iconsax.arrow_right_3, size: 18, color: kSub),
            ]),
          ),
        ),
      ),
    );
  }

}


/// Переключатель пуш-уведомлений (персональный, действует на все
/// устройства этого менеджера).
class _NotifyToggleCard extends ConsumerStatefulWidget {
  const _NotifyToggleCard({required this.uid});
  final String uid;

  @override
  ConsumerState<_NotifyToggleCard> createState() => _NotifyToggleCardState();
}

class _NotifyToggleCardState extends ConsumerState<_NotifyToggleCard> {
  bool? _enabled; // null = загрузка

  @override
  void initState() {
    super.initState();
    ref.read(pushServiceProvider).isEnabled(widget.uid).then((v) {
      if (mounted) setState(() => _enabled = v);
    });
  }

  Future<void> _toggle(bool v) async {
    setState(() => _enabled = v);
    try {
      await ref.read(pushServiceProvider).setEnabled(widget.uid, v);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(v ? 'Уведомления включены' : 'Уведомления отключены'),
            duration: const Duration(seconds: 2),
          ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _enabled = !v);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _enabled ?? true;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: (on ? kTealDeep : kSub).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(on ? Iconsax.notification : Iconsax.notification_circle, size: 21, color: on ? kTealDeep : kSub),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Уведомления', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 2),
            Text(on ? 'Пуши о новых сообщениях и звонках' : 'Отключены — пуши не приходят',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: kSub)),
          ]),
        ),
        _enabled == null
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : Switch(value: on, activeThumbColor: Colors.white, activeTrackColor: kTeal, onChanged: _toggle),
      ]),
    );
  }
}

/// Состояние WhatsApp-канала (Wazzup): работает ли номер прямо сейчас.
class _ChannelCard extends ConsumerWidget {
  const _ChannelCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(channelStatusProvider);
    final ch = async.value;
    final loading = ch == null;
    final ok = ch?.isActive == true;
    final unknown = ch?.isUnknown == true;
    final color = loading || unknown ? kSub : (ok ? const Color(0xFF23A35F) : const Color(0xFFC6403C));

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
          child: Icon(ok ? Iconsax.tick_circle : (unknown || loading ? Iconsax.wifi : Iconsax.warning_2), size: 21, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('WhatsApp-канал', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 2),
            Text(
              loading
                  ? 'Проверяем…'
                  : (ch.phone?.isNotEmpty == true ? '${ch.label} · ${formatPhone(ch.phone)}' : ch.label),
              maxLines: 2,
              style: TextStyle(fontSize: 12.5, color: ok ? kSub : color, fontWeight: ok ? FontWeight.w400 : FontWeight.w600),
            ),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 20, color: kSub),
          tooltip: 'Обновить',
          onPressed: () => ref.invalidate(channelStatusProvider),
        ),
      ]),
    );
  }
}

/// Правило «один менеджер в системе» — включает админ.
/// На самого админа не распространяется: он работает параллельно.
class _SingleSessionCard extends ConsumerWidget {
  const _SingleSessionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(singleSessionEnabledProvider);
    final on = async.value ?? true;
    final loading = !async.hasValue;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: (on ? const Color(0xFF5A6ACF) : kSub).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(on ? Iconsax.lock_1 : Iconsax.unlock, size: 21, color: on ? const Color(0xFF5A6ACF) : kSub),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Один менеджер в системе', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 2),
            Text(
              on
                  ? 'Новый вход выкидывает предыдущего. Вас как админа не касается.'
                  : 'Менеджеры могут работать одновременно.',
              maxLines: 2,
              style: const TextStyle(fontSize: 12.5, color: kSub),
            ),
          ]),
        ),
        loading
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : Switch(
                value: on,
                activeThumbColor: Colors.white,
                activeTrackColor: kTeal,
                onChanged: (v) async {
                  try {
                    await ref.read(sessionServiceProvider).setEnabled(v);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(
                          content: Text(v
                              ? 'Включено: одновременно работает один менеджер'
                              : 'Выключено: менеджеры работают одновременно'),
                          duration: const Duration(seconds: 2),
                        ));
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
                    }
                  }
                },
              ),
      ]),
    );
  }
}
