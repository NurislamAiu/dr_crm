import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tokens.dart';

/// Выбранный скин акцента. Смена перекрашивает всё приложение и запоминается
/// на устройстве — сервер об этом знать не должен, это личная настройка.
class SkinController extends StateNotifier<AppSkin> {
  SkinController() : super(AppSkin.ocean) {
    _load();
  }

  static const _key = 'appSkin';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      final found = AppSkin.values.where((s) => s.name == saved);
      if (found.isNotEmpty) state = found.first;
    } catch (_) {
      /* нет доступа к хранилищу — остаётся скин по умолчанию */
    }
  }

  Future<void> set(AppSkin skin) async {
    state = skin;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, skin.name);
    } catch (_) {
      /* не сохранилось — на текущую сессию скин всё равно применён */
    }
  }
}

final skinProvider = StateNotifierProvider<SkinController, AppSkin>((_) => SkinController());
