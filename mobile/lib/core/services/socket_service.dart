// Socket.io client for real-time message delivery.
//
// Server (src/socket.ts) accepts a JWT in the handshake auth
// payload, verifies it, then joins the socket to `user:<userId>` on
// connection. Every incoming DM fans out via
// `io.to('user:' + recipientId).emit('new_message', message)`
// (see src/routes/conversations.ts in the message-send handler).
//
// This class is a thin Dart-side wrapper that exposes the
// `new_message` firehose as a broadcast stream. The conversation
// detail screen subscribes and filters by conversation id; the
// auth provider owns the connect/disconnect lifecycle.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class SocketService {
  final String _apiBaseUrl;
  io.Socket? _socket;
  final _newMessageStream = StreamController<Map<String, dynamic>>.broadcast();

  SocketService(this._apiBaseUrl);

  /// Broadcast stream of raw `new_message` payloads from the server.
  /// The payload matches the Message JSON shape — caller is
  /// responsible for filtering by conversation id and decrypting
  /// E2EE envelopes before rendering.
  Stream<Map<String, dynamic>> get newMessages => _newMessageStream.stream;

  bool get isConnected => _socket?.connected ?? false;

  /// Connect with the current auth token. Disconnects any existing
  /// connection first so reconnecting with a new token (e.g. after
  /// refresh) doesn't leak a zombie socket.
  void connect(String authToken) {
    disconnect();
    final socket = io.io(
      _apiBaseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': authToken})
          .disableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(10)
          .setReconnectionDelay(1000)
          .build(),
    );

    socket.onConnect((_) {
      debugPrint('[socket] connected');
    });
    socket.onDisconnect((reason) {
      debugPrint('[socket] disconnected: $reason');
    });
    socket.onConnectError((err) {
      debugPrint('[socket] connect error: $err');
    });
    socket.on('new_message', (data) {
      if (data is Map) {
        final map = Map<String, dynamic>.from(data);
        debugPrint(
            '[socket] new_message conv=${map['conversation_id']} id=${map['id']}');
        _newMessageStream.add(map);
      }
    });

    socket.connect();
    _socket = socket;
  }

  void disconnect() {
    final s = _socket;
    if (s == null) return;
    s.disconnect();
    s.clearListeners();
    s.close();
    _socket = null;
  }

  void dispose() {
    disconnect();
    _newMessageStream.close();
  }
}
