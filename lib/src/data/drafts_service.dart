import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Недописанные сообщения по чатам.
///
/// Менеджер начал печатать, вышел посмотреть запись — текст должен остаться.
/// Живут только на устройстве: это личный черновик, а не общий с командой.
class DraftsController extends StateNotifier<Map<String, String>> {
  DraftsController() : super(const {}) {
    _load();
  }

  static const _key = 'chatDrafts';

  Future<void> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null || raw.isEmpty) return;
      final map = (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
      state = Map.unmodifiable(map);
    } catch (_) {
      // Битые данные — просто начинаем с пустого списка.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (state.isEmpty) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, jsonEncode(state));
      }
    } catch (_) {
      /* не смогли сохранить — не роняем ввод */
    }
  }

  /// Запомнить черновик чата (пустой — забыть).
  void set(String conversationId, String text) {
    final t = text.trim();
    if (t.isEmpty) {
      clear(conversationId);
      return;
    }
    if (state[conversationId] == t) return;
    state = Map.unmodifiable({...state, conversationId: t});
    _save();
  }

  void clear(String conversationId) {
    if (!state.containsKey(conversationId)) return;
    final next = {...state}..remove(conversationId);
    state = Map.unmodifiable(next);
    _save();
  }

  String? of(String conversationId) => state[conversationId];
}

/// Черновики всех чатов: экран чата пишет, список чатов показывает пометку.
final draftsProvider =
    StateNotifierProvider<DraftsController, Map<String, String>>((_) => DraftsController());
