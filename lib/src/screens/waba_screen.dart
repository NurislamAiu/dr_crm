import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax/iconsax.dart';

import '../data/waba_service.dart';
import '../state/providers.dart';
import 'soft_ui.dart';

const _pageBg = Color(0xFFF1F8F6);
const _waba = Color(0xFF2E7CF6);
const _wabaDeep = Color(0xFF1B5BC4);

/// Канал WhatsApp и шаблоны WABA.
///
/// Здесь админ переключает CRM между обычным номером (QR) и WABA и выбирает
/// шаблон, которым клиента зовут в чат, если он молчит больше 24 часов.
class WabaScreen extends ConsumerStatefulWidget {
  const WabaScreen({super.key});

  @override
  ConsumerState<WabaScreen> createState() => _WabaScreenState();
}

class _WabaScreenState extends ConsumerState<WabaScreen> {
  List<WazzupChannelInfo>? _channels;
  String _current = '';
  List<WabaTemplate>? _templates;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final svc = ref.read(wabaServiceProvider);
      final ch = await svc.channels();
      List<WabaTemplate> tpl = const [];
      // Шаблоны есть только у WABA — на QR-аккаунте запрос вернёт пусто.
      if (ch.channels.any((c) => c.isWaba)) {
        tpl = await svc.templates().catchError((_) => <WabaTemplate>[]);
      }
      if (!mounted) return;
      setState(() {
        _channels = ch.channels;
        _current = ch.current;
        _templates = tpl;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchTo(WazzupChannelInfo c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Переключить канал?'),
        content: Text(
          'CRM начнёт отправлять сообщения с номера ${formatPhone(c.phone)}'
          '${c.isWaba ? ' (WABA)' : ' (обычный WhatsApp)'}.\n\n'
          '${c.isWaba ? 'Клиентам, которые молчат больше 24 часов, будет уходить шаблон-приглашение.' : 'Действует лимит темпа — рассылки уходят с паузами.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _wabaDeep),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Переключить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(wabaServiceProvider).save(channelId: c.channelId);
      if (mounted) setState(() => _current = c.channelId);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickOpener(WabaTemplate t) async {
    setState(() => _busy = true);
    try {
      // Сколько переменных в шаблоне — столько и подставим: имя, затем дата.
      const sources = ['name', 'date', 'text'];
      final vars = List.generate(t.vars, (i) => i < sources.length ? sources[i] : 'name');
      await ref.read(wabaServiceProvider).save(openerTemplateId: t.id, openerVars: vars);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(wabaSettingsProvider).value ?? const WabaSettings();
    final channels = _channels ?? const <WazzupChannelInfo>[];
    final active = channels.where((c) => c.channelId == _current).firstOrNull;
    final wabaOn = active?.isWaba ?? false;

    return Scaffold(
      backgroundColor: _pageBg,
      body: Column(children: [
        SoftHeader(
          color: _waba,
          colorDeep: _wabaDeep,
          title: 'Канал WhatsApp',
          dateLabel: wabaOn ? 'Работает через WABA' : 'Обычный номер (QR)',
          showBack: true,
          actions: [
            SoftHeaderButton(icon: Icons.refresh_rounded, tooltip: 'Обновить', accent: _wabaDeep, onTap: _load),
          ],
        ),
        Expanded(
          child: Container(
            transform: Matrix4.translationValues(0, -22, 0),
            decoration: const BoxDecoration(
              color: _pageBg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: _busy && _channels == null
                ? const Center(child: CircularProgressIndicator(color: _wabaDeep))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(15, 22, 15, 28),
                    children: [
                      if (_error != null) _errorCard(_error!),
                      _sectionTitle('Каналы аккаунта Wazzup'),
                      for (final c in channels) _channelCard(c),
                      if (channels.isEmpty && _error == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('Каналов пока нет', style: TextStyle(fontSize: 13.5, color: kSub)),
                        ),
                      const SizedBox(height: 18),
                      _sectionTitle('Шаблон приглашения'),
                      _hintCard(wabaOn),
                      for (final t in (_templates ?? const <WabaTemplate>[]))
                        _templateCard(t, selected: t.id == settings.openerTemplateId),
                      if ((_templates ?? const []).isEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(4, 4, 4, 4),
                          child: Text(
                            'Шаблонов нет. Они появятся, когда канал WABA будет оплачен и Meta одобрит тексты '
                            '— шаблоны создаются в личном кабинете Wazzup.',
                            style: TextStyle(fontSize: 13, color: kSub, height: 1.4),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
        child: Text(t, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: kInk)),
      );

  Widget _errorCard(String e) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
        decoration: BoxDecoration(color: const Color(0xFFFBEDEC), borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          const Icon(Iconsax.warning_2, size: 18, color: Color(0xFFC6403C)),
          const SizedBox(width: 10),
          Expanded(child: Text(e, style: const TextStyle(fontSize: 12.5, color: Color(0xFFC6403C)))),
        ]),
      );

  Widget _hintCard(bool wabaOn) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
        decoration: BoxDecoration(
          color: _waba.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          wabaOn
              ? 'Если клиент молчит больше 24 часов, свободный текст WhatsApp не пропустит. CRM отправит этот '
                  'шаблон, а сообщение менеджера подождёт в очереди и уйдёт сразу после ответа клиента.'
              : 'Сейчас работает обычный номер по QR — шаблоны не нужны. Настройка пригодится после переключения на WABA.',
          style: const TextStyle(fontSize: 12.5, color: kInk, height: 1.4),
        ),
      );

  Widget _channelCard(WazzupChannelInfo c) {
    final isCurrent = c.channelId == _current;
    final accent = c.isWaba ? _wabaDeep : kTealDeep;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isCurrent ? accent.withValues(alpha: 0.45) : Colors.transparent),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _busy || isCurrent ? null : () => _switchTo(c),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 13, 13, 13),
            child: Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                child: Icon(c.isWaba ? Iconsax.verify : Iconsax.mobile, size: 20, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(formatPhone(c.phone),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kInk)),
                    ),
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                      child: Text(c.isWaba ? 'WABA' : 'QR',
                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: accent)),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    isCurrent ? 'используется · ${c.stateLabel}' : c.stateLabel,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                      color: c.isReady ? (isCurrent ? accent : kSub) : const Color(0xFFB07A10),
                    ),
                  ),
                ]),
              ),
              if (isCurrent)
                Icon(Iconsax.tick_circle, size: 20, color: accent)
              else
                const Icon(Iconsax.arrow_right_3, size: 17, color: kSub),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _templateCard(WabaTemplate t, {required bool selected}) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? _wabaDeep.withValues(alpha: 0.45) : Colors.transparent),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _busy || !t.isApproved ? null : () => _pickOpener(t),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(t.title.isEmpty ? 'Без названия' : t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: kInk)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: (t.isApproved ? kTealDeep : const Color(0xFFB07A10)).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(t.statusLabel,
                        style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: t.isApproved ? kTealDeep : const Color(0xFFB07A10))),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 7),
                    const Icon(Iconsax.tick_circle, size: 18, color: _wabaDeep),
                  ],
                ]),
                if (t.body.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
                    decoration: BoxDecoration(color: const Color(0xFFF7FAF9), borderRadius: BorderRadius.circular(13)),
                    child: Text(t.body,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: kInk, height: 1.35)),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '${t.language.toUpperCase()} · ${t.category.toLowerCase()}'
                  '${t.vars > 0 ? ' · переменных: ${t.vars}' : ''}',
                  style: const TextStyle(fontSize: 11.5, color: kSub),
                ),
              ]),
            ),
          ),
        ),
      );
}
