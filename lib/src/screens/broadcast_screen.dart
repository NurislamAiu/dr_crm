import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../data/broadcast_repository.dart';
import '../state/providers.dart';
import 'soft_ui.dart';

const _pageBg = Color(0xFFF1F8F6);

/// 55 вариантов текста — каждому контакту уходит свой, чтобы WhatsApp
/// не принял одинаковые сообщения за спам. Переменные {name} и {date}.
const _defaultVariants = <String>[
  'Здравствуйте, {name}!\nDR.TOITAYEV: напоминаем, что {date} у Вас запись к врачу.\nДля подтверждения, переноса или отмены записи просто ответьте на это сообщение.',
  'Добрый день, {name}!\nКлиника DR.TOITAYEV напоминает о Вашем приёме {date}. Подтвердить, перенести или отменить визит можно ответом в этот чат.',
  '{name}, здравствуйте!\nНапоминаем, что {date} Вас ждёт приём у врача в клинике DR.TOITAYEV. Чтобы подтвердить или изменить запись — напишите нам в WhatsApp.',
  'Здравствуйте, {name}!\nЭто клиника DR.TOITAYEV. Ваш приём назначен на {date}. Пожалуйста, подтвердите визит ответным сообщением.',
  'Добрый день, {name}!\nНапоминаем: {date} у Вас визит к врачу в DR.TOITAYEV. Для подтверждения, переноса или отмены ответьте в этот чат.',
  '{name}, добрый день!\nКлиника DR.TOITAYEV ждёт Вас на приёме {date}. Чтобы подтвердить запись — просто напишите нам.',
  'Здравствуйте, {name}!\nНапоминаем о Вашей записи к врачу {date} (DR.TOITAYEV). Подтвердите, пожалуйста, визит ответным сообщением.',
  'Уважаемый(ая) {name}!\nНапоминаем, что {date} у Вас запланирован приём в клинике DR.TOITAYEV. Подтвердить или изменить запись можно здесь, в WhatsApp.',
  'Здравствуйте, {name}!\nDR.TOITAYEV напоминает: приём у врача — {date}. Просим подтвердить визит ответом в этот чат.',
  'Добрый день, {name}!\nЖдём Вас {date} на приёме в клинике DR.TOITAYEV. Для подтверждения или переноса ответьте на это сообщение.',
  '{name}, здравствуйте!\nВаша запись в клинику DR.TOITAYEV — {date}. Будете? Ответьте, пожалуйста, на это сообщение.',
  'Здравствуйте, {name}!\nПодтвердите, пожалуйста, Вашу запись на {date} в клинике DR.TOITAYEV — достаточно ответить «+» на это сообщение.',
  'Добрый день, {name}!\nЭто DR.TOITAYEV. Напоминаем про Ваш визит {date}. Если планы изменились — напишите нам, перенесём на удобное время.',
  '{name}, добрый день!\nПодтверждаете запись на {date}? Клиника DR.TOITAYEV. Ответьте «+», если будете, или напишите, если нужно перенести.',
  'Здравствуйте, {name}!\nВаш приём в DR.TOITAYEV состоится {date}. Пожалуйста, дайте знать ответным сообщением, всё ли в силе.',
  'Добрый день, {name}!\nКлиника DR.TOITAYEV: у Вас запись {date}. Просим подтвердить визит или сообщить о переносе ответом в чат.',
  '{name}, здравствуйте!\nПишем из клиники DR.TOITAYEV: напоминаем про приём {date}. Ждём Ваше подтверждение в ответном сообщении.',
  'Здравствуйте, {name}!\nНебольшое напоминание от DR.TOITAYEV — Ваш визит к врачу назначен на {date}. Подтвердите, пожалуйста, ответом.',
  'Добрый день, {name}!\nНапоминаем Вам о записи в клинику DR.TOITAYEV {date}. Если всё в силе — ответьте «+». Если нет — напишите, подберём другое время.',
  '{name}, добрый день!\nDR.TOITAYEV на связи: ждём Вас {date}. Подтвердите визит, пожалуйста, ответным сообщением.',
  'Здравствуйте, {name}!\nПроверьте, пожалуйста: Ваш приём в клинике DR.TOITAYEV — {date}. Ответьте на сообщение, чтобы подтвердить.',
  'Добрый день, {name}!\nУ Вас запись к врачу {date} в DR.TOITAYEV. Будем ждать! Если не получается прийти — предупредите нас ответом в чат.',
  '{name}, здравствуйте!\nКлиника DR.TOITAYEV подтверждает Вашу запись: {date}. Пожалуйста, ответьте, если время остаётся удобным.',
  'Здравствуйте, {name}!\n{date} у Вас приём в клинике DR.TOITAYEV. Просьба подтвердить визит любым ответом на это сообщение.',
  'Добрый день, {name}!\nДружеское напоминание от клиники DR.TOITAYEV: визит к врачу — {date}. Ответьте «+», чтобы подтвердить.',
  '{name}, добрый день!\nВаша запись: {date}, клиника DR.TOITAYEV. Подтвердите, пожалуйста, или напишите о переносе.',
  'Здравствуйте, {name}!\nМы ждём Вас в DR.TOITAYEV {date}. Чтобы подтвердить запись, просто ответьте на это сообщение.',
  'Добрый день, {name}!\nНапоминание: Ваш приём у врача клиники DR.TOITAYEV назначен на {date}. Подтвердите визит ответом в чат, пожалуйста.',
  '{name}, здравствуйте!\nDR.TOITAYEV: подтверждаете ли Вы запись на {date}? Ответьте одним сообщением — «да» или «перенести».',
  'Здравствуйте, {name}!\nУточняем Вашу запись в клинику DR.TOITAYEV на {date}. Пожалуйста, подтвердите её ответным сообщением.',
  'Добрый день, {name}!\nВаш визит в DR.TOITAYEV уже скоро — {date}. Дайте, пожалуйста, знать, что будете.',
  '{name}, добрый день!\nЗаписали Вас на {date} — клиника DR.TOITAYEV. Просим подтвердить визит в ответном сообщении.',
  'Здравствуйте, {name}!\nНапоминаем о визите {date} в клинику DR.TOITAYEV. Если время неудобно — напишите, предложим другое.',
  'Добрый день, {name}!\nКлиника DR.TOITAYEV ждёт Вас {date}. Подтвердить или перенести запись можно одним сообщением в этот чат.',
  '{name}, здравствуйте!\nПожалуйста, подтвердите Ваш приём {date} в DR.TOITAYEV — ответа «+» будет достаточно.',
  'Здравствуйте, {name}!\nУ Вас запланирован визит к врачу {date} (клиника DR.TOITAYEV). Ответьте, пожалуйста, чтобы мы знали, что Вы будете.',
  'Добрый день, {name}!\nЭто администратор клиники DR.TOITAYEV. Напоминаю о Вашей записи {date}. Подтвердите, пожалуйста, ответом.',
  '{name}, добрый день!\nХотим убедиться, что Ваш визит {date} в DR.TOITAYEV в силе. Ответьте на это сообщение, пожалуйста.',
  'Здравствуйте, {name}!\nВаша запись в клинике DR.TOITAYEV назначена: {date}. Просим подтвердить или сообщить об изменениях.',
  'Добрый день, {name}!\nСкоро Ваш приём — {date}, клиника DR.TOITAYEV. Будете? Ждём короткий ответ в этом чате.',
  '{name}, здравствуйте!\nПодтвердите, пожалуйста, запись к врачу {date}. Клиника DR.TOITAYEV. Для переноса просто напишите нам.',
  'Здравствуйте, {name}!\nКлиника DR.TOITAYEV приглашает Вас на приём {date}. Пожалуйста, подтвердите визит ответным сообщением.',
  'Добрый день, {name}!\nНапоминаем: Ваша запись — {date}. DR.TOITAYEV. Если что-то поменялось, сообщите нам ответом в чат.',
  '{name}, добрый день!\nЖдём Вас на приёме {date} в клинике DR.TOITAYEV. Одно ответное сообщение — и запись подтверждена.',
  'Здравствуйте, {name}!\nПросим подтвердить Ваш визит в DR.TOITAYEV, назначенный на {date}. Ответьте «+» или напишите о переносе.',
  'Добрый день, {name}!\nВаш приём в клинике DR.TOITAYEV — {date}. Подтвердите, пожалуйста, чтобы мы сохранили за Вами время.',
  '{name}, здравствуйте!\nВремя Вашего визита в DR.TOITAYEV: {date}. Ответьте на сообщение, если всё в силе.',
  'Здравствуйте, {name}!\nНапоминаем про запись {date} в клинику DR.TOITAYEV. Подтверждение — одним ответом в этот чат.',
  'Добрый день, {name}!\nDR.TOITAYEV: Ваш визит назначен на {date}. Пожалуйста, подтвердите или предупредите о переносе.',
  '{name}, добрый день!\nПроверяем записи на ближайшие дни: Ваша — {date}, клиника DR.TOITAYEV. Подтвердите, пожалуйста, ответом.',
  'Здравствуйте, {name}!\nБудем рады видеть Вас {date} в клинике DR.TOITAYEV. Просим подтвердить визит ответным сообщением.',
  'Добрый день, {name}!\nВаш приём у врача — {date}. Клиника DR.TOITAYEV. Ответьте «+», если будете, — так мы сохраним Ваше время.',
  '{name}, здравствуйте!\nЗапись сохраняем за Вами: {date}, DR.TOITAYEV. Пожалуйста, ответьте, что придёте.',
  'Здравствуйте, {name}!\nНапоминание о приёме: {date}, клиника DR.TOITAYEV. Если нужно перенести или отменить — просто напишите нам.',
  'Добрый день, {name}!\nДо встречи {date} в DR.TOITAYEV! Подтвердите, пожалуйста, визит коротким ответом в этот чат.',
];

/// 6 вариантов запроса предоплаты. Реквизиты во всех одинаковые — меняются
/// только формулировки, чтобы WhatsApp не считал рассылку спамом.
const _paymentVariants = <String>[
  """Здравствуйте, {name}! Для подтверждения записи необходимо внести предоплату.

ВТБ Россия

2204 3603 0004 5901

ALIYA BAIKENOVA

После внесения предоплаты отправьте чек, имя и контакт пациента.
В случае отмены записи предоплата не возвращается.""",

  """{name}, добрый день! Чтобы закрепить за Вами время приёма, нужна предоплата.

Реквизиты для перевода:
ВТБ Россия
2204 3603 0004 5901
ALIYA BAIKENOVA

После оплаты пришлите, пожалуйста, чек, имя и контакт пациента.
Обратите внимание: при отмене записи предоплата не возвращается.""",

  """Здравствуйте, {name}!
Ваше время бронируется после предоплаты.

Перевод на карту:
ВТБ Россия
2204 3603 0004 5901
ALIYA BAIKENOVA

Пришлите чек с именем и контактом пациента — и мы подтвердим запись.
Предоплата при отмене не возвращается.""",

  """Добрый день, {name}!
Запись подтверждается после внесения предоплаты.

ВТБ Россия
2204 3603 0004 5901
ALIYA BAIKENOVA

Отправьте, пожалуйста, чек об оплате, имя и контакт пациента.
Напоминаем: в случае отмены предоплата не возвращается.""",

  """{name}, здравствуйте!
Чтобы время осталось за Вами, просим внести предоплату.

Куда переводить:
ВТБ Россия
2204 3603 0004 5901
ALIYA BAIKENOVA

Затем отправьте чек, имя и контакт пациента в этот чат.
Предоплата не возвращается при отмене записи.""",

  """Здравствуйте, {name}!
Для брони приёма требуется предоплата.

ВТБ Россия
2204 3603 0004 5901
ALIYA BAIKENOVA

После перевода отправьте нам чек, имя и контакт пациента — запись будет подтверждена.
При отмене записи предоплата не возвращается.""",
];

/// Как выбирать вариант текста для каждого контакта.
enum _Mode { rotate, random, single }

/// Экран массовой рассылки. Отправка — НА СЕРВЕРЕ (Cloud Function, пауза 20 c):
/// после запуска приложение можно закрыть, прогресс приходит из Firestore,
/// по завершении — пуш.
class BroadcastScreen extends ConsumerStatefulWidget {
  const BroadcastScreen({super.key});

  @override
  ConsumerState<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends ConsumerState<BroadcastScreen> {
  final List<TextEditingController> _variants =
      _defaultVariants.map((t) => TextEditingController(text: t)).toList();
  final _contacts = TextEditingController();

  _Mode _mode = _Mode.rotate;
  int _singleIndex = 0; // выбранный вариант в режиме «Один»
  bool _variantsExpanded = false; // свёрнутый список текстов (экономия места)
  bool _starting = false;

  @override
  void dispose() {
    for (final c in _variants) {
      c.dispose();
    }
    _contacts.dispose();
    super.dispose();
  }

  List<String> _activeVariants() => _variants.map((c) => c.text).where((t) => t.trim().isNotEmpty).toList();

  void _addVariant() => setState(() => _variants.add(TextEditingController()));

  /// Загрузить пресет текстов (заменяет текущие варианты).
  void _loadPreset(List<String> texts, {required bool single}) {
    setState(() {
      for (final c in _variants) {
        c.dispose();
      }
      _variants
        ..clear()
        ..addAll(texts.map((t) => TextEditingController(text: t)));
      _singleIndex = 0;
      _mode = single ? _Mode.single : _Mode.rotate;
    });
  }

  void _removeVariant(int i) {
    setState(() {
      final c = _variants.removeAt(i);
      c.dispose();
    });
  }

  List<({String name, String phone, String date})> _parse() {
    return _contacts.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map((line) {
          final sep = line.contains(';') ? ';' : ',';
          final parts = line.split(sep);
          return (
            name: parts.isNotEmpty ? parts[0].trim() : '',
            phone: parts.length > 1 ? parts[1].trim() : '',
            date: parts.length > 2 ? parts[2].trim() : '',
          );
        })
        .where((r) => r.phone.isNotEmpty)
        .toList();
  }

  bool _canSend(int parsedCount) {
    if (parsedCount == 0 || _starting) return false;
    if (_mode == _Mode.single) {
      return _singleIndex < _variants.length && _variants[_singleIndex].text.trim().isNotEmpty;
    }
    return _activeVariants().isNotEmpty;
  }

  Future<void> _start() async {
    final rows = _parse();
    final variants = _activeVariants();
    if (rows.isEmpty || variants.isEmpty) return;
    final uid = ref.read(appConfigProvider).userId;
    if (uid == null) return;

    setState(() => _starting = true);
    try {
      await ref.read(broadcastRepositoryProvider).start(
            createdBy: uid,
            rows: rows,
            variants: variants,
            mode: _mode.name,
            singleIndex: _singleIndex,
          );
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('Рассылка запущена на сервере — приложение можно закрыть. По завершении придёт пуш.'),
            duration: Duration(seconds: 4),
          ));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось запустить: $e')));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop(BroadcastDoc b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Остановить рассылку?'),
        content: Text('Отправлено ${b.sent} из ${b.total}. Остальные не получат сообщение.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Продолжить рассылку')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC6403C)),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Остановить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await ref.read(broadcastRepositoryProvider).stop(b.id);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = ref.watch(latestBroadcastProvider).value;
    final running = b?.isRunning == true;
    final parsedCount = _parse().length;

    return Scaffold(
      backgroundColor: _pageBg,
      body: Column(
        children: [
          SoftHeader(
            color: kTeal,
            colorDeep: kTealDeep,
            title: 'Рассылка',
            dateLabel: weekdayDateRu(DateTime.now()),
            actions: const [],
            strip: Row(children: [
              HeaderStat(value: running ? '${b!.total}' : '$parsedCount', label: 'контактов'),
              const SizedBox(width: 9),
              HeaderStat(
                value: b == null ? '—' : '${b.sent}✓ ${b.failed}✗',
                label: 'отправлено',
              ),
              const SizedBox(width: 9),
              HeaderStat(
                value: running ? '${b!.pending}' : '20 c',
                label: running ? 'осталось · сервер шлёт' : 'пауза (анти-бан)',
              ),
            ]),
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
                  if (running) _serverBanner(),
                  if (!running) ...[
                    _variantsCard(),
                    _contactsCard(parsedCount),
                    const SizedBox(height: 4),
                  ],
                  _actionButton(b, running, parsedCount),
                  if (b != null && b.rows.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    if (!running) _resultBanner(b),
                    _progress(b),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Плашка «идёт на сервере».
  Widget _serverBanner() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kTeal.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kTeal.withValues(alpha: 0.3)),
        ),
        child: const Row(children: [
          Icon(Iconsax.cloud, size: 20, color: kTealDeep),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Рассылка идёт на сервере: приложение можно закрыть, телефон — выключить. По завершении придёт пуш.',
              style: TextStyle(fontSize: 12.5, color: kTealDeep, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
      );

  /// Итог последней рассылки (когда не идёт).
  Widget _resultBanner(BroadcastDoc b) {
    final (label, color) = switch (b.status) {
      'done' => ('Завершена: ${b.sent} ✓${b.failed > 0 ? ' · ${b.failed} ✗' : ''}', const Color(0xFF23A35F)),
      'stopped' => ('Остановлена: успели ${b.sent} из ${b.total}', kAmberDeep),
      'error' => ('Ошибка рассылки', const Color(0xFFC6403C)),
      _ => ('', kSub),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Icon(b.status == 'done' ? Iconsax.tick_circle : Iconsax.info_circle, size: 17, color: color),
        const SizedBox(width: 7),
        Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }

  // ── Карточки ────────────────────────────────────────────────────────────

  BoxDecoration get _cardDeco => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      );

  Widget _cardTitle(IconData icon, String title, {Widget? trailing}) => Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, size: 18, color: kTealDeep),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk))),
        ?trailing,
      ]);

  Widget _presetChip({required IconData icon, required String label, required Color color, required VoidCallback? onTap}) {
    return Material(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          ]),
        ),
      ),
    );
  }

  Widget _modeChips() {
    const items = [(_Mode.rotate, 'По очереди'), (_Mode.random, 'Рандом'), (_Mode.single, 'Один')];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: const Color(0xFFEFF4F2), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        for (final (m, label) in items)
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _mode = m),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _mode == m ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: _mode == m
                      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 8, offset: const Offset(0, 2))]
                      : null,
                ),
                alignment: Alignment.center,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: _mode == m ? FontWeight.w700 : FontWeight.w500,
                        color: _mode == m ? kTealDeep : kSub)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _variantsCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: _cardDeco,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _cardTitle(Iconsax.message_text_1, 'Тексты · ${_variants.length}'),
        const SizedBox(height: 12),
        Row(children: [
          _presetChip(
            icon: Iconsax.notification,
            label: 'Напоминания',
            color: kTealDeep,
            onTap: () => _loadPreset(_defaultVariants, single: false),
          ),
          const SizedBox(width: 8),
          _presetChip(
            icon: Iconsax.card,
            label: 'Предоплата',
            color: const Color(0xFFB07A10),
            onTap: () => _loadPreset(_paymentVariants, single: false),
          ),
        ]),
        const SizedBox(height: 12),
        _modeChips(),
        const SizedBox(height: 8),
        Text(
          switch (_mode) {
            _Mode.single => 'Всем уходит один выбранный вариант (отметьте его ниже).',
            _Mode.random => 'Каждому — случайный вариант из списка.',
            _Mode.rotate => 'Каждому — следующий вариант по кругу.',
          },
          style: const TextStyle(fontSize: 12, color: kSub),
        ),
        const SizedBox(height: 4),
        const Text('Переменные: {name} — имя, {date} — дата приёма', style: TextStyle(fontSize: 12, color: kSub)),
        const SizedBox(height: 10),
        // Переключатель «развернуть/свернуть» — редактирование по требованию.
        Material(
          color: const Color(0xFFEFF4F2),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _variantsExpanded = !_variantsExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Icon(_variantsExpanded ? Iconsax.arrow_up_2 : Iconsax.arrow_down_1, size: 16, color: kTealDeep),
                const SizedBox(width: 8),
                Text(
                  _variantsExpanded ? 'Свернуть варианты' : 'Показать варианты · ${_variants.length}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kTealDeep),
                ),
              ]),
            ),
          ),
        ),
        if (!_variantsExpanded && _mode == _Mode.single) ...[
          // В режиме «Один» выбор варианта доступен и в свёрнутом виде.
          const SizedBox(height: 10),
          for (var i = 0; i < _variants.length; i++)
            InkWell(
              onTap: () => setState(() => _singleIndex = i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Icon(
                    _singleIndex == i ? Iconsax.tick_circle : Iconsax.record_circle,
                    size: 18,
                    color: _singleIndex == i ? kTealDeep : kSub.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _variants[i].text.trim().isEmpty ? 'Вариант ${i + 1} (пустой)' : _variants[i].text.trim().split('\n').first,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: kSub),
                    ),
                  ),
                ]),
              ),
            ),
        ],
        if (_variantsExpanded) ...[
          const SizedBox(height: 14),
          for (var i = 0; i < _variants.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  if (_mode == _Mode.single) ...[
                    GestureDetector(
                      onTap: () => setState(() => _singleIndex = i),
                      child: Icon(
                        _singleIndex == i ? Iconsax.tick_circle : Iconsax.record_circle,
                        size: 20,
                        color: _singleIndex == i ? kTealDeep : kSub.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                    child: Text('Вариант ${i + 1}',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: kTealDeep)),
                  ),
                  const Spacer(),
                  if (_variants.length > 1)
                    GestureDetector(
                      onTap: () => _removeVariant(i),
                      child: const Icon(Iconsax.trash, size: 18, color: Color(0xFFD9776F)),
                    ),
                ]),
                const SizedBox(height: 7),
                _multiline(_variants[i], minLines: 3, mono: false),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addVariant,
              icon: const Icon(Iconsax.add, size: 18),
              label: const Text('Добавить вариант'),
              style: TextButton.styleFrom(foregroundColor: kTealDeep),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _contactsCard(int parsedCount) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: _cardDeco,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _cardTitle(
          Iconsax.profile_2user,
          'Контакты',
          trailing: parsedCount > 0
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(9)),
                  child: Text('$parsedCount',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: kTealDeep)),
                )
              : null,
        ),
        const SizedBox(height: 10),
        const Text('По одному в строке:  Имя;+7XXXXXXXXXX;дата', style: TextStyle(fontSize: 12, color: kSub)),
        const SizedBox(height: 8),
        _multiline(_contacts,
            minLines: 5,
            mono: true,
            hint: 'Дархан;+77014004647;22 июля\nАйгуль;+77771234567;23 июля',
            onChanged: (_) => setState(() {})),
      ]),
    );
  }

  Widget _multiline(TextEditingController c,
      {required int minLines, required bool mono, String? hint, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: c,
      minLines: minLines,
      maxLines: minLines + 6,
      onChanged: onChanged,
      style: TextStyle(fontSize: 14, fontFamily: mono ? 'monospace' : null, height: 1.35, color: kInk),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 13, fontFamily: mono ? 'monospace' : null, color: kSub.withValues(alpha: 0.6)),
        filled: true,
        fillColor: const Color(0xFFF2F6F5),
        contentPadding: const EdgeInsets.all(12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kTeal, width: 1.5)),
      ),
    );
  }

  Widget _actionButton(BroadcastDoc? b, bool running, int parsedCount) {
    if (running && b != null) {
      return SizedBox(
        height: 54,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFC6403C),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          onPressed: () => _stop(b),
          icon: const Icon(Iconsax.stop, size: 20),
          label: Text('Остановить · отправлено ${b.sent} из ${b.total}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      );
    }
    final enabled = _canSend(parsedCount);
    return SizedBox(
      height: 54,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: kTeal,
          disabledBackgroundColor: const Color(0xFFD6E4E0),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        onPressed: enabled ? _start : null,
        icon: _starting
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
            : const Icon(Iconsax.send_1, size: 20),
        label: Text('Отправить рассылку${parsedCount > 0 ? ' · $parsedCount' : ''}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _progress(BroadcastDoc b) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      decoration: _cardDeco,
      child: Column(
        children: [
          for (var i = 0; i < b.rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                border: i < b.rows.length - 1
                    ? Border(bottom: BorderSide(color: Colors.black.withValues(alpha: 0.05)))
                    : null,
              ),
              child: Row(children: [
                _statusIcon(b.rows[i].status),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(b.rows[i].name.isEmpty ? '—' : b.rows[i].name,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: kInk)),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(formatPhone(b.rows[i].phone),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kSub, fontSize: 12.5)),
                      ),
                    ]),
                    if (b.rows[i].date.isNotEmpty)
                      Text(b.rows[i].date, style: const TextStyle(fontSize: 12, color: kSub)),
                    if (b.rows[i].error != null)
                      Text(b.rows[i].error!, style: const TextStyle(fontSize: 12, color: Color(0xFFC6403C))),
                  ]),
                ),
                if ((b.rows[i].variant ?? 0) > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(7)),
                    child: Text('в${b.rows[i].variant}',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: kTealDeep)),
                  ),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _statusIcon(String s) => switch (s) {
        'sent' => const Icon(Iconsax.tick_circle, color: Color(0xFF2E9E5B), size: 22),
        'failed' => const Icon(Iconsax.close_circle, color: Color(0xFFC6403C), size: 22),
        _ => Icon(Iconsax.clock, color: kSub.withValues(alpha: 0.6), size: 21),
      };
}
