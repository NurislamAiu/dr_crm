import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Конфигурация подключения к backend CRM.
///
/// Значения по умолчанию рассчитаны на локальную разработку. На Android-эмуляторе
/// host-машина доступна как 10.0.2.2 (не localhost) — измените в настройках.
class AppConfig extends ChangeNotifier {
  AppConfig({
    required this.apiBaseUrl,
    required this.realtimeUrl,
    required this.organizationId,
    required this.userId,
  });

  String apiBaseUrl;
  String realtimeUrl;
  String organizationId;

  /// DEV: id менеджера (уходит в заголовке x-user-id). Этап 7 заменит на JWT-логин.
  String userId;

  static const _kApi = 'apiBaseUrl';
  static const _kRt = 'realtimeUrl';
  static const _kOrg = 'organizationId';
  static const _kUser = 'userId';

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppConfig(
      apiBaseUrl: prefs.getString(_kApi) ?? 'http://localhost:3000',
      realtimeUrl: prefs.getString(_kRt) ?? 'http://localhost:3001',
      organizationId: prefs.getString(_kOrg) ?? 'default',
      userId: prefs.getString(_kUser) ?? '',
    );
  }

  Future<void> save({
    required String apiBaseUrl,
    required String realtimeUrl,
    required String organizationId,
    required String userId,
  }) async {
    this.apiBaseUrl = apiBaseUrl.trim();
    this.realtimeUrl = realtimeUrl.trim();
    this.organizationId = organizationId.trim();
    this.userId = userId.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kApi, this.apiBaseUrl);
    await prefs.setString(_kRt, this.realtimeUrl);
    await prefs.setString(_kOrg, this.organizationId);
    await prefs.setString(_kUser, this.userId);
    notifyListeners();
  }

  bool get isConfigured => userId.isNotEmpty;
}
