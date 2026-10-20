import 'dart:io';
import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../network/api_service.dart';
import 'deep_link.dart';

/// Manages FCM token registration and push notification handling.
class PushNotificationService {
  final ApiService _apiService;

  /// Called when a notification tap should produce an in-app navigation.
  /// Wired from `authProvider` to set `pendingDeepLinkProvider`, which AsideApp
  /// observes and translates into a `router.go(...)` call.
  final void Function(String route) _onDeepLink;
  final void Function(String postId)? _onNewPost;

  String? _currentToken;
  int _generation = 0;
  bool _initialized = false;
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _tapSubscription;

  PushNotificationService(
    this._apiService, {
    required void Function(String route) onDeepLink,
    void Function(String postId)? onNewPost,
  })  : _onDeepLink = onDeepLink,
        _onNewPost = onNewPost;

  /// Initialize push notifications: request permissions, get token, register.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final generation = ++_generation;
    try {
      final messaging = FirebaseMessaging.instance;

      // Request permission (iOS shows a dialog, Android auto-grants)
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (generation != _generation) return;

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[Push] Permission denied');
        _initialized = false;
        return;
      }

      // Get FCM token
      final token = await messaging.getToken();
      if (generation != _generation) return;
      if (token != null) {
        _currentToken = token;
        await _registerToken(token);
      }
      if (generation != _generation) return;

      // Listen for token refreshes
      _tokenSubscription = messaging.onTokenRefresh.listen((newToken) {
        _currentToken = newToken;
        _registerToken(newToken);
      });

      // Handle foreground messages
      _messageSubscription =
          FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      // Handle taps while the app is backgrounded (resumed from tray).
      _tapSubscription =
          FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

      // Handle the tap that cold-started the app from a terminated state.
      // This must run AFTER the router is mounted; the callback sets a Riverpod
      // provider which AsideApp observes and routes on the next frame, so the
      // timing self-corrects even if initialize() runs before the first build.
      final initial = await messaging.getInitialMessage();
      if (generation != _generation) return;
      if (initial != null) {
        _handleNotificationTap(initial);
      }

      debugPrint('[Push] FCM Token: $token');
    } catch (_) {
      if (generation == _generation) _initialized = false;
      rethrow;
    }
  }

  /// Translate a tapped notification's data payload into an in-app route and
  /// hand it off to the router via [pendingDeepLinkProvider].
  void _handleNotificationTap(RemoteMessage message) {
    final route = routeForNotificationData(message.data);
    debugPrint('[Push] Tap route: $route data=${message.data}');
    if (route != null) _onDeepLink(route);
  }

  /// Register the FCM token with the backend.
  Future<void> _registerToken(String token) async {
    try {
      final platform = Platform.isIOS ? 'ios' : 'android';
      await _apiService.registerDeviceToken(token, platform);
      debugPrint('[Push] Token registered');
    } catch (e) {
      debugPrint('[Push] Token registration failed: $e');
    }
  }

  /// Re-assert the current FCM token with the backend.
  ///
  /// The server upserts device tokens, so this is safe to call on every
  /// resume. It closes the case where the backend deleted a stale token
  /// while the app was not running, but the local SDK still returns the
  /// same cached token and therefore never emits an on-token-refresh event.
  Future<void> reregister() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      _currentToken = token;
      await _registerToken(token);
    } catch (e) {
      debugPrint('[Push] reregister failed: $e');
    }
  }

  /// Handle messages received while the app is in the foreground.
  void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('[Push] Foreground message: ${message.notification?.title}');
    final postId = message.data['post_id'];
    if (message.data['type'] == 'new_post' && postId is String) {
      _onNewPost?.call(postId);
    }
  }

  /// Unregister the token on logout.
  Future<void> unregister() async {
    _generation++;
    _initialized = false;
    await _tokenSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _tapSubscription?.cancel();
    if (_currentToken != null) {
      try {
        await _apiService.unregisterDeviceToken(_currentToken!);
        debugPrint('[Push] Token unregistered');
      } catch (e) {
        debugPrint('[Push] Token unregister failed: $e');
      }
    }
    _currentToken = null;
  }
}
