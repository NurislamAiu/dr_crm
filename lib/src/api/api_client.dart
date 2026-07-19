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
        if (_config.token != null) 'authorization': 'Bearer ${_config.token}',
      };

  Uri _uri(String path) => Uri.parse('${_config.apiBaseUrl}$path');

  /// Логин: возвращает данные сессии (токен сохраняется вызывающим).
  Future<Map<String, dynamic>> login(String email, String password) async {
    final res = await http.post(
      _uri('/api/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    _ensureOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Поиск по диалогам (номер/имя) и по тексту сообщений.
  Future<SearchResults> search(String query) async {
    final res = await http.get(
      _uri('/api/search?q=${Uri.encodeQueryComponent(query)}'),
      headers: _headers,
    );
    _ensureOk(res);
    return SearchResults.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Отметить диалог прочитанным (сброс непрочитанных).
  Future<void> markRead(String conversationId) async {
    final res = await http.post(_uri('/api/conversations/$conversationId/read'), headers: _headers);
    _ensureOk(res);
  }

  Future<void> conversationAction(String conversationId, String action, {String? toUserId}) async {
    final res = await http.post(
      _uri('/api/conversations/$conversationId/action'),
      headers: _headers,
      body: jsonEncode({'action': action, 'toUserId': ?toUserId}),
    );
    _ensureOk(res);
  }

  Future<List<Map<String, dynamic>>> getNotes(String conversationId) async {
    final res = await http.get(_uri('/api/conversations/$conversationId/notes'), headers: _headers);
    _ensureOk(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return ((data['notes'] as List<dynamic>?) ?? []).cast<Map<String, dynamic>>();
  }

  Future<void> addNote(String conversationId, String text) async {
    final res = await http.post(
      _uri('/api/conversations/$conversationId/notes'),
      headers: _headers,
      body: jsonEncode({'text': text}),
    );
    _ensureOk(res);
  }

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

  /// Изменить текст своего отправленного сообщения (§16).
  Future<void> editMessage(String messageId, String text) async {
    final res = await http.patch(
      _uri('/api/messages/$messageId'),
      headers: _headers,
      body: jsonEncode({'text': text}),
    );
    _ensureOk(res);
  }

  /// Удалить своё отправленное сообщение (§16).
  Future<void> deleteMessage(String messageId) async {
    final res = await http.delete(_uri('/api/messages/$messageId'), headers: _headers);
    _ensureOk(res);
  }

  /// Короткоживущий signed URL вложения (сервер отдаёт ссылку на наш S3).
  Future<String> attachmentUrl(String attachmentId) async {
    final res = await http.get(_uri('/api/attachments/$attachmentId/url'), headers: _headers);
    _ensureOk(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['url'] as String;
  }

  /// Отправка вложения (multipart). Файл уходит только на наш backend (§14).
  Future<void> sendMedia(
    String conversationId, {
    required List<int> bytes,
    required String fileName,
    required String mimeType,
    String? caption,
  }) async {
    final req = http.MultipartRequest(
      'POST',
      _uri('/api/conversations/$conversationId/messages/send-media'),
    );
    if (_config.token != null) req.headers['authorization'] = 'Bearer ${_config.token}';
    req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
    if (caption != null && caption.isNotEmpty) req.fields['caption'] = caption;
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
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
