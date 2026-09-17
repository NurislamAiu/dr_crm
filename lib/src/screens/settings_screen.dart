import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../state/providers.dart';
import 'analytics_screen.dart';
import 'files_screen.dart';
import 'quick_replies_screen.dart';
import 'firebase_managers_screen.dart';
import 'managers_screen.dart';
import 'soft_ui.dart';
import 'waba_broadcast_screen.dart';
import 'waba_screen.dart';

const _pageBg = Color(0xFFF2F2F7); // surface дизайн-системы

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
                padding: EdgeInsets.fromLTRB(15, 22, 15, 28 + MediaQuery.paddingOf(context).bottom),
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
                  // Канал WhatsApp: обычный номер (QR) или WABA + шаблоны Meta.
                  // Приветствие Telegram-бота правится в Firestore:
                  // config/telegram.
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
                  // «Автоответчик» убран: в WhatsApp на все входящие отвечают
                  // менеджеры сами (решение владельца). Автоматика осталась
                  // только в Telegram — тексты бота в config/telegram.
                  // Рассылка одобренным шаблоном Meta: единственный законный
                  // способ написать первым тем, кто давно молчит.
                  if (_isAdmin && config.isFirebase)
                    _navCard(
                      icon: Iconsax.send_2,
                      color: const Color(0xFF23A35F),
                      title: 'Рассылка',
                      subtitle: 'Шаблон WhatsApp Business по списку или по записям на день',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const WabaBroadcastScreen()),
                      ),
                    ),
                  if (_isAdmin && config.isFirebase)
                    _navCard(
                      icon: Icons.telegram,
                      color: const Color(0xFF229ED9),
                      title: 'Номера из переписки',
                      subtitle: 'Проставить клиентам номера, написанные текстом в чатах',
                      onTap: () => _runFixNames(context),
                    ),
                  // Поиск вложений по дням: кто прислал PDF (чек, заключение)
                  // или фото — с фильтром по стране номера.
                  if (config.isFirebase)
                    _navCard(
                      icon: Iconsax.document_text,
                      color: const Color(0xFFC6403C),
                      title: 'Файлы из чатов',
                      subtitle: 'Кто прислал PDF или фото — поиск по дням',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const FilesScreen()),
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
                  // Отвечать некому (отпуск, праздники) — переключатель на
                  // это касается ВСЕХ клиентов, поэтому только у админа.
                  if (_isAdmin && config.isFirebase) const _VacationReplyCard(),
                  if (_isAdmin && config.isFirebase) const _AiReplyCard(),
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

  /// Ремонт Telegram-чатов по кнопке (только админ): имена чатов = номера,
  /// плюс подтягиваются номера, написанные клиентами текстом в переписке.
  Future<void> _runFixNames(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Обновляю номера…')));
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('tgFixNames')
          .call<Map<String, dynamic>>({});
      final fixedCount = (res.data['fixedCount'] as num?)?.toInt() ?? 0;
      final scanned = (res.data['scanned'] as num?)?.toInt() ?? 0;
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(fixedCount == 0
            ? 'Все чаты уже в порядке (проверено: $scanned)'
            : 'Обновлено чатов: $fixedCount (проверено: $scanned)'),
      ));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не получилось: $e')));
    }
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

/// Автоответ «недоступны» на дни, когда отвечать некому (отпуск, праздники).
///
/// Пока включён, каждому НОВОМУ обращению (первый /start в Telegram, первое
/// сообщение в WhatsApp) уходит этот текст вместо обычного приветствия —
/// существующей переписки переключатель не касается, это не рассылка.
class _VacationReplyCard extends StatefulWidget {
  const _VacationReplyCard();

  @override
  State<_VacationReplyCard> createState() => _VacationReplyCardState();
}

class _VacationReplyCardState extends State<_VacationReplyCard> {
  static const _defaultText = 'Добрый день!\n\n'
      'Извините, с 21 по 23 августа не сможем вам ответить.\n'
      'Напишите ваш вопрос — менеджер свяжется с вами позже.';

  final _controller = TextEditingController();
  bool _loadedOnce = false;
  bool _dirty = false;
  bool _saving = false;

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('config').doc('vacationReply');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _setEnabled(bool v) async {
    try {
      await _doc.set({'enabled': v, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(v
                ? 'Включено: новым обращениям уходит это сообщение'
                : 'Выключено: новым обращениям снова уходит обычное приветствие'),
            duration: const Duration(seconds: 2),
          ));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  Future<void> _saveText() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await _doc.set({'text': text, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      if (mounted) {
        setState(() => _dirty = false);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Текст сохранён'), duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _doc.snapshots(),
      builder: (context, snap) {
        final d = snap.data?.data();
        final on = d?['enabled'] == true;
        final remoteText = (d?['text'] as String? ?? '').trim();
        // Текст из базы подставляем в поле только один раз при загрузке —
        // дальше это поле принадлежит менеджеру, а не стриму.
        if (!_loadedOnce && snap.hasData) {
          _loadedOnce = true;
          _controller.text = remoteText.isNotEmpty ? remoteText : _defaultText;
        }
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (on ? const Color(0xFFC0447B) : kSub).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.beach_access_rounded, size: 21, color: on ? const Color(0xFFC0447B) : kSub),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Автоответ «недоступны»', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
                  const SizedBox(height: 2),
                  Text(
                    on
                        ? 'Включено — новым обращениям уходит это вместо приветствия'
                        : 'Выключено — работает обычное приветствие',
                    maxLines: 2,
                    style: const TextStyle(fontSize: 12.5, color: kSub),
                  ),
                ]),
              ),
              Switch(
                value: on,
                activeThumbColor: Colors.white,
                activeTrackColor: const Color(0xFFC0447B),
                onChanged: _setEnabled,
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) {
                if (!_dirty) setState(() => _dirty = true);
              },
              style: const TextStyle(fontSize: 13.5, color: kInk),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: const Color(0xFFF2F5F7),
                contentPadding: const EdgeInsets.all(12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                hintText: 'Текст сообщения…',
              ),
            ),
            if (_dirty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: kTeal),
                  onPressed: _saving ? null : _saveText,
                  child: _saving
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Сохранить текст'),
                ),
              ),
            ],
          ]),
        );
      },
    );
  }
}

/// Черновик ответа от ИИ (Claude Haiku) на первое сообщение нового чата.
///
/// ИИ ничего не отправляет клиенту сам — только предлагает текст менеджеру
/// прямо в переписке, тот решает: отправить, поправить или скрыть. База
/// знаний — реальные тексты быстрых ответов, цена подставляется по
/// гражданству номера (Казахстан — «Прайс», остальные — цена для других
/// стран). Тема «Обучение»/«БАДы» ИИ не касается — там свой сценарий.
class _AiReplyCard extends StatelessWidget {
  const _AiReplyCard();

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('config').doc('aiReply');

  Future<void> _setEnabled(BuildContext context, bool v) async {
    try {
      await _doc.set({'enabled': v, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(v
                ? 'Включено: на первое сообщение новых чатов ИИ будет предлагать черновик'
                : 'Выключено: черновиков от ИИ больше не будет'),
            duration: const Duration(seconds: 2),
          ));
      }
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _doc.snapshots(),
      builder: (context, snap) {
        final on = snap.data?.data()?['enabled'] == true;
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
                color: (on ? const Color(0xFF5A4FCF) : kSub).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Iconsax.magic_star, size: 21, color: on ? const Color(0xFF5A4FCF) : kSub),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Черновик от ИИ', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
                const SizedBox(height: 2),
                Text(
                  on
                      ? 'Включено — предлагает ответ на первое сообщение новых чатов, менеджер подтверждает'
                      : 'Выключено — менеджеры отвечают сами, как раньше',
                  maxLines: 2,
                  style: const TextStyle(fontSize: 12.5, color: kSub),
                ),
              ]),
            ),
            Switch(
              value: on,
              activeThumbColor: Colors.white,
              activeTrackColor: const Color(0xFF5A4FCF),
              onChanged: (v) => _setEnabled(context, v),
            ),
          ]),
        );
      },
    );
  }
}
