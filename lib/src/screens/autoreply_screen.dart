import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/autoreply_service.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';

/// Настройка автоответчика (config/autoReply).
class AutoReplyScreen extends ConsumerStatefulWidget {
  const AutoReplyScreen({super.key});

  @override
  ConsumerState<AutoReplyScreen> createState() => _AutoReplyScreenState();
}

class _AutoReplyScreenState extends ConsumerState<AutoReplyScreen> {
  AutoReplyConfig? _cfg;
  final _text = TextEditingController();
  final _missedText = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await ref.read(autoReplyServiceProvider).load();
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _text.text = cfg.text;
      _missedText.text = cfg.missedCallText;
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _missedText.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cfg = _cfg!;
    cfg.text = _text.text.trim();
    cfg.missedCallText = _missedText.text.trim();
    if (cfg.enabled && cfg.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Укажите текст автоответа')));
      return;
    }
    if (cfg.missedCallEnabled && cfg.missedCallText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Укажите текст для пропущенного звонка')));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(autoReplyServiceProvider).save(cfg);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Сохранено')));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _cfg;
    return Scaffold(
      appBar: AppBar(title: const Text('Автоответчик', style: TextStyle(fontWeight: FontWeight.w800))),
      body: cfg == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  value: cfg.enabled,
                  activeThumbColor: AppColors.brand,
                  title: const Text('Включить автоответчик', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Автоматический ответ на входящее сообщение'),
                  onChanged: (v) => setState(() => cfg.enabled = v),
                ),
                const SizedBox(height: 8),
                const Text('Текст автоответа', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                TextField(
                  controller: _text,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Здравствуйте! Спасибо за обращение. Мы ответим в рабочее время.',
                  ),
                ),
                const Divider(height: 32),
                SwitchListTile(
                  value: cfg.outsideHoursOnly,
                  activeThumbColor: AppColors.brand,
                  title: const Text('Только вне рабочих часов'),
                  subtitle: const Text('В рабочее время автоответ не шлётся (отвечают менеджеры)'),
                  onChanged: (v) => setState(() => cfg.outsideHoursOnly = v),
                ),
                if (cfg.outsideHoursOnly) ...[
                  Row(children: [
                    Expanded(child: _hourPicker('Начало', cfg.workStart, (v) => setState(() => cfg.workStart = v))),
                    const SizedBox(width: 12),
                    Expanded(child: _hourPicker('Конец', cfg.workEnd, (v) => setState(() => cfg.workEnd = v))),
                  ]),
                  const SizedBox(height: 8),
                  _hourPicker('Часовой пояс (UTC+)', cfg.tzOffset, (v) => setState(() => cfg.tzOffset = v), max: 12, min: -12),
                ],
                const Divider(height: 32),
                const Text('Не чаще одного раза в', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  for (final m in const [30, 60, 180, 360, 720, 1440])
                    ChoiceChip(
                      label: Text(_cooldownLabel(m)),
                      selected: cfg.cooldownMin == m,
                      selectedColor: AppColors.brand.withValues(alpha: 0.18),
                      onSelected: (_) => setState(() => cfg.cooldownMin = m),
                    ),
                ]),
                const Divider(height: 32),
                SwitchListTile(
                  value: cfg.missedCallEnabled,
                  activeThumbColor: AppColors.brand,
                  title: const Text('Автоответ на пропущенный звонок', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Когда клиент звонит и не дозвонился (кулдаун 1 ч)'),
                  onChanged: (v) => setState(() => cfg.missedCallEnabled = v),
                ),
                if (cfg.missedCallEnabled) ...[
                  const SizedBox(height: 6),
                  TextField(
                    controller: _missedText,
                    minLines: 2,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Извините, мы не успели ответить на звонок. Напишите нам сюда — поможем.',
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  height: 50,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                        : const Text('Сохранить', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
    );
  }

  String _cooldownLabel(int m) {
    if (m < 60) return '$m мин';
    if (m < 1440) return '${m ~/ 60} ч';
    return '${m ~/ 1440} д';
  }

  Widget _hourPicker(String label, int value, ValueChanged<int> onChanged, {int min = 0, int max = 23}) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      child: DropdownButton<int>(
        value: value,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: [for (var h = min; h <= max; h++) DropdownMenuItem(value: h, child: Text(max <= 23 ? '${h.toString().padLeft(2, '0')}:00' : '$h'))],
        onChanged: (v) => onChanged(v ?? value),
      ),
    );
  }
}
