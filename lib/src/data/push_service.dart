import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../screens/firebase_chats.dart';
import 'firestore_chat_repository.dart';

/// Глобальный навигатор — нужен, чтобы открыть чат по тапу на пуш.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Пуш-уведомления (FCM): регистрация токена устройства в fcmTokens/{uid}
/// и открытие чата по тапу. Пуши шлёт Cloud Function на входящие сообщения.
class PushService {
  final _fm = FirebaseMessaging.instance;
  bool _ready = false;

  Future<void> register(String uid) async {
    try {
      final s = await _fm.requestPermission(alert: true, badge: true, sound: true);
      debugPrint('[PUSH] разрешение: ${s.authorizationStatus}');
      if (s.authorizationStatus == AuthorizationStatus.denied) return;

      Future<void> save(String t) async {
        await FirebaseFirestore.instance.collection('fcmTokens').doc(uid).set({
          'tokens': FieldValue.arrayUnion([t]),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        debugPrint('[PUSH] ✅ токен сохранён в fcmTokens/$uid');
      }

      if (!_ready) {
        _ready = true;
        // Важно: слушатель ДО получения токена — если APNs выдаст токен позже,
        // onTokenRefresh всё равно сработает и мы его сохраним.
        _fm.onTokenRefresh.listen((t) {
          debugPrint('[PUSH] onTokenRefresh: ${t.substring(0, 16)}…');
          save(t);
        });
        FirebaseMessaging.onMessageOpenedApp.listen(_openChat);
        _fm.getInitialMessage().then((m) {
          if (m != null) _openChat(m);
        });
      }

      // iOS: сначала ждём APNs-токен; Android — сразу FCM-токен.
      String? token;
      for (var i = 0; i < 12 && token == null; i++) {
        try {
          if (Platform.isIOS) {
            final apns = await _fm.getAPNSToken();
            if (apns == null) {
              debugPrint('[PUSH] жду APNs-токен (${i + 1}/12)…');
              await Future<void>.delayed(const Duration(seconds: 3));
              continue;
            }
          }
          token = await _fm.getToken();
        } catch (e) {
          debugPrint('[PUSH] getToken (попытка ${i + 1}/12): $e');
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      if (token == null) {
        debugPrint('[PUSH] ❌ токен пока не получен — сохранится автоматически, когда придёт (onTokenRefresh)');
        return;
      }
      debugPrint('[PUSH] ✅ токен получен: ${token.substring(0, 16)}…');
      await save(token);
    } catch (e) {
      // Симулятор без APNs / плагин не собран (нужен полный rebuild).
      debugPrint('[PUSH] ❌ ошибка регистрации: $e');
    }
  }

  /// Включены ли уведомления у менеджера (нет поля = включены).
  Future<bool> isEnabled(String uid) async {
    try {
      final d = await FirebaseFirestore.instance.collection('fcmTokens').doc(uid).get();
      return d.data()?['enabled'] != false;
    } catch (_) {
      return true;
    }
  }

  /// Включить/выключить уведомления для этого менеджера (все его устройства).
  Future<void> setEnabled(String uid, bool enabled) async {
    await FirebaseFirestore.instance.collection('fcmTokens').doc(uid).set({
      'enabled': enabled,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    if (enabled) await register(uid); // убедимся, что токен на месте
  }

  void _openChat(RemoteMessage m) {
    final chatId = m.data['chatId'] as String?;
    if (chatId == null || chatId.isEmpty) return;
    final conv = FsConversation(
      id: chatId,
      name: (m.data['name'] as String?) ?? '+$chatId',
      phone: (m.data['phone'] as String?) ?? chatId,
      preview: null,
      lastMessageAt: null,
      unreadCount: 0,
    );
    appNavigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => FirebaseChatScreen(conversation: conv)),
    );
  }
}
