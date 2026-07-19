import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/models.dart';

/// REST-клиент backend'а CRM. Никогда не обращается к Wazzup напрямую — только
/// к нашему backend (§1). Авторизация DEV: заголовок x-user-id (Этап 7 — JWT).
class ApiClient {
  ApiClient(this._config);
  final AppConfig _config;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'x-org-id': _config.organizationId,
        if (_config.userId.isNotEmpty) 'x-user-id': _config.userId,
      };

  Uri _uri(String path) => Uri.parse('${_config.apiBaseUrl}$path');

  Future<List<Conversation>> getConversations({String? status}) async {
    final q = status != null ? '?status=$status' : '';
    final res = await http.get(_uri('/api/conversations$q'), headers: _headers);
    _ensureOk(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return ((data['conversations'] as List<dynamic>?) ?? [])
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Message>> getMessages(String conversationId) async {
    final res = await http.get(
      _uri('/api/conversations/$conversationId/messages'),
      headers: _headers,
    );
    _ensureOk(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return ((data['messages'] as List<dynamic>?) ?? [])
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Отправка текста. Возвращает id локального сообщения (status=queued).
  Future<String> sendMessage(
    String conversationId,
    String text, {
    String? replyToMessageId,
  }) async {
    final res = await http.post(
      _uri('/api/conversations/$conversationId/messages/send'),
      headers: _headers,
      body: jsonEncode({
        'text': text,
        'replyToMessageId': ?replyToMessageId,
      }),
    );
    _ensureOk(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['messageId'] as String;
  }

  Future<void> retryMessage(String messageId) async {
    final res = await http.post(_uri('/api/messages/$messageId/retry'), headers: _headers);
    _ensureOk(res);
  }

  void _ensureOk(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      String message = 'Ошибка ${res.statusCode}';
      try {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        if (body['error'] is String) message = body['error'] as String;
      } catch (_) {}
      throw ApiException(res.statusCode, message);
    }
  }
}

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => message;
}
