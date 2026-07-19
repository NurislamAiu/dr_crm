import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Конфигурация подключения и сессия менеджера.
///
/// Авторизация — JWT (Bearer), полученный через /api/auth/login. На
/// Android-эмуляторе host доступен как 10.0.2.2 (не localhost).
class AppConfig extends ChangeNotifier {
  AppConfig({
    required this.apiBaseUrl,
    required this.realtimeUrl,
    this.token,
    this.userId,
    this.userName,
    this.role,
  });

  String apiBaseUrl;
  String realtimeUrl;
  String? token;
  String? userId;
  String? userName;
  String? role;

  static const _kApi = 'apiBaseUrl';
  static const _kRt = 'realtimeUrl';
  static const _kToken = 'token';
  static const _kUserId = 'userId';
  static const _kUserName = 'userName';
  static const _kRole = 'role';

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppConfig(
      apiBaseUrl: prefs.getString(_kApi) ?? 'http://localhost:3000',
      realtimeUrl: prefs.getString(_kRt) ?? 'http://localhost:3001',
      token: prefs.getString(_kToken),
      userId: prefs.getString(_kUserId),
      userName: prefs.getString(_kUserName),
      role: prefs.getString(_kRole),
    );
  }

  bool get isAuthenticated => token != null && token!.isNotEmpty;

  Future<void> setEndpoints(String apiBaseUrl, String realtimeUrl) async {
    this.apiBaseUrl = apiBaseUrl.trim();
    this.realtimeUrl = realtimeUrl.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kApi, this.apiBaseUrl);
    await prefs.setString(_kRt, this.realtimeUrl);
    notifyListeners();
  }

  Future<void> setSession({
    required String token,
    required String userId,
    required String userName,
    required String role,
  }) async {
    this.token = token;
    this.userId = userId;
    this.userName = userName;
    this.role = role;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, token);
    await prefs.setString(_kUserId, userId);
    await prefs.setString(_kUserName, userName);
    await prefs.setString(_kRole, role);
    notifyListeners();
  }

  Future<void> logout() async {
    token = null;
    userId = null;
    userName = null;
    role = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kUserId);
    await prefs.remove(_kUserName);
    await prefs.remove(_kRole);
    notifyListeners();
  }
}
