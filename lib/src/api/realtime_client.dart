import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config/app_config.dart';

/// Событие реального времени, пришедшее от Socket.IO backend (§23).
class RealtimeEvent {
  RealtimeEvent(this.event, this.payload, {this.conversationId});
  final String event;
  final String? conversationId;
  final Map<String, dynamic> payload;
}

/// Клиент Socket.IO. Подключается к комнате своей организации; события
/// пробрасываются в broadcast-стрим. При обрыве соединения socket.io сам
/// переподключается; UI при этом дозагружает данные REST-запросом (§23).
class RealtimeClient {
  RealtimeClient(this._config);
  final AppConfig _config;

  io.Socket? _socket;
  final _controller = StreamController<RealtimeEvent>.broadcast();

  Stream<RealtimeEvent> get events => _controller.stream;
  bool get isConnected => _socket?.connected ?? false;

  static const _eventNames = <String>[
    'conversation.created',
    'conversation.updated',
    'conversation.assigned',
    'message.created',
    'message.updated',
    'message.status.updated',
    'channel.state.updated',
    'notification.created',
  ];

  void connect() {
    if (_socket != null) return;
    final socket = io.io(
      _config.realtimeUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'organizationId': _config.organizationId, 'userId': _config.userId})
          .enableReconnection()
          .build(),
    );
    for (final name in _eventNames) {
      socket.on(name, (data) {
        if (data is Map) {
          final map = Map<String, dynamic>.from(data);
          _controller.add(RealtimeEvent(
            name,
            Map<String, dynamic>.from((map['payload'] as Map?) ?? {}),
            conversationId: map['conversationId'] as String?,
          ));
        }
      });
    }
    socket.connect();
    _socket = socket;
  }

  void subscribeConversation(String conversationId) {
    _socket?.emit('conversation:subscribe', conversationId);
  }

  void unsubscribeConversation(String conversationId) {
    _socket?.emit('conversation:unsubscribe', conversationId);
  }

  void dispose() {
    _socket?.dispose();
    _socket = null;
    _controller.close();
  }
}
