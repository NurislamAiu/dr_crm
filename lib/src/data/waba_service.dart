import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Канал Wazzup: обычный WhatsApp по QR или WABA.
class WazzupChannelInfo {
  const WazzupChannelInfo({
    required this.channelId,
    required this.phone,
    required this.transport,
    required this.isWaba,
    required this.state,
  });

  final String channelId;
  final String phone;
  final String transport;
  final bool isWaba;
  final String state;

  /// Человеческое состояние канала (значения из документации Wazzup).
  String get stateLabel => switch (state) {
        'active' => 'работает',
        'init' => 'запускается',
        'disabled' => 'выключен',
        'phoneUnavailable' => 'нет связи с телефоном',
        'qridle' => 'нужен QR-код',
        'openelsewhere' => 'открыт в другом аккаунте',
        'notEnoughMoney' => 'не оплачен',
        'foreignphone' => 'QR отсканирован другим номером',
        'unauthorized' => 'не авторизован',
        'waitForPassword' => 'ждёт пароль 2FA',
        'blocked' => 'заблокирован Facebook',
        'onModeration' => 'на модерации',
        'rejected' => 'отклонён',
        _ => state,
      };

  bool get isReady => state == 'active';

  static WazzupChannelInfo fromMap(Map<Object?, Object?> m) => WazzupChannelInfo(
        channelId: '${m['channelId'] ?? ''}',
        phone: '${m['phone'] ?? ''}',
        transport: '${m['transport'] ?? ''}',
        isWaba: m['isWaba'] == true,
        state: '${m['state'] ?? ''}',
      );
}

/// Шаблон WABA, одобренный Meta (из кабинета Wazzup).
class WabaTemplate {
  const WabaTemplate({
    required this.id,
    required this.title,
    required this.status,
    required this.category,
    required this.language,
    required this.header,
    required this.body,
    required this.vars,
  });

  final String id;
  final String title;
  final String status;
  final String category;
  final String language;
  final String header;
  final String body;

  /// Сколько переменных {{1}}, {{2}} ждёт шаблон.
  final int vars;

  bool get isApproved => status.toUpperCase() == 'APPROVED';

  String get statusLabel => switch (status.toUpperCase()) {
        'APPROVED' => 'одобрен',
        'PENDING' => 'на модерации',
        'REJECTED' => 'отклонён',
        _ => status,
      };

  static WabaTemplate fromMap(Map<Object?, Object?> m) => WabaTemplate(
        id: '${m['id'] ?? ''}',
        title: '${m['title'] ?? ''}',
        status: '${m['status'] ?? ''}',
        category: '${m['category'] ?? ''}',
        language: '${m['language'] ?? ''}',
        header: '${m['header'] ?? ''}',
        body: '${m['body'] ?? ''}',
        vars: (m['vars'] as num?)?.toInt() ?? 0,
      );
}

/// Настройки WABA (config/waba) — что подставлять в шаблон приглашения.
class WabaSettings {
  const WabaSettings({
    this.openerTemplateId = '',
    this.openerVars = const ['name'],
    this.openerCooldownHours = 24,
  });

  final String openerTemplateId;
  final List<String> openerVars;
  final int openerCooldownHours;

  static WabaSettings fromMap(Map<String, dynamic> d) => WabaSettings(
        openerTemplateId: (d['openerTemplateId'] ?? '') as String,
        openerVars: ((d['openerVars'] ?? const ['name']) as List).map((e) => '$e').toList(),
        openerCooldownHours: (d['openerCooldownHours'] as num?)?.toInt() ?? 24,
      );
}

/// Работа с каналом и шаблонами WABA через Cloud Functions.
class WabaService {
  WabaService({FirebaseFirestore? db, FirebaseFunctions? functions})
      : _db = db ?? FirebaseFirestore.instance,
        _fn = functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  final FirebaseFirestore _db;
  final FirebaseFunctions _fn;

  /// Каналы аккаунта Wazzup + какой сейчас рабочий.
  Future<({String current, List<WazzupChannelInfo> channels})> channels() async {
    final res = await _fn.httpsCallable('wazzupChannelList').call<Map<Object?, Object?>>();
    final data = res.data;
    final list = (data['channels'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(WazzupChannelInfo.fromMap)
        .toList();
    return (current: '${data['current'] ?? ''}', channels: list);
  }

  /// Шаблоны WABA из кабинета Wazzup.
  Future<List<WabaTemplate>> templates() async {
    final res = await _fn.httpsCallable('wabaTemplates').call<Map<Object?, Object?>>();
    return (res.data['templates'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(WabaTemplate.fromMap)
        .toList();
  }

  /// Переключить рабочий канал и/или настроить шаблон приглашения.
  Future<void> save({
    String? channelId,
    String? openerTemplateId,
    List<String>? openerVars,
    int? openerCooldownHours,
  }) async {
    await _fn.httpsCallable('setChannelConfig').call<Map<Object?, Object?>>({
      // ?value — запись попадёт в map, только если значение не null.
      'channelId': ?channelId,
      'openerTemplateId': ?openerTemplateId,
      'openerVars': ?openerVars,
      'openerCooldownHours': ?openerCooldownHours,
    });
  }

  /// Текущие настройки WABA.
  Stream<WabaSettings> watchSettings() =>
      _db.collection('config').doc('waba').snapshots().map((s) => WabaSettings.fromMap(s.data() ?? {}));
}
