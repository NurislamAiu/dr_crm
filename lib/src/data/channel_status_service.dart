import 'package:cloud_functions/cloud_functions.dart';

/// Состояние WhatsApp-канала в Wazzup.
class ChannelStatus {
  const ChannelStatus({required this.state, this.phone, this.error});
  final String state; // active | qridle | disabled | ... | unknown
  final String? phone;
  final String? error;

  /// Канал работает — сообщения уходят.
  bool get isActive => state == 'active';

  /// Пока не знаем (нет сети / первый запрос) — не пугаем менеджера.
  bool get isUnknown => state == 'unknown' || state.isEmpty;

  /// Человеческое описание проблемы для баннера.
  String get label => switch (state) {
        'active' => 'Канал работает',
        'init' => 'Канал подключается…',
        'qridle' => 'Нужно отсканировать QR — WhatsApp отключён',
        'openelsewhere' => 'WhatsApp открыт на другом устройстве',
        'phoneUnavailable' => 'Телефон недоступен — включите интернет на телефоне',
        'foreignphone' => 'Номер занят другим подключением',
        'disabled' => 'Канал отключён в Wazzup',
        'nopayment' => 'Не оплачен тариф Wazzup',
        'blocked' => 'Номер заблокирован WhatsApp',
        'timeout' => 'Нет связи с WhatsApp',
        // Статус ещё не получен (нет сети / первый запуск) — не пугаем.
        'unknown' => 'Проверяем состояние…',
        _ => 'Канал недоступен',
      };
}

/// Проверка состояния канала через Cloud Function channelStatus.
class ChannelStatusService {
  ChannelStatusService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');
  final FirebaseFunctions _functions;

  Future<ChannelStatus> load() async {
    try {
      final res = await _functions.httpsCallable('channelStatus').call<Map<String, dynamic>>();
      final d = res.data;
      return ChannelStatus(
        state: (d['state'] ?? 'unknown') as String,
        phone: d['phone'] as String?,
        error: d['error'] as String?,
      );
    } catch (e) {
      return ChannelStatus(state: 'unknown', error: '$e');
    }
  }
}
