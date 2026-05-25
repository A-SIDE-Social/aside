import 'dart:io';
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

  String? _currentToken;

  PushNotificationService(
    this._apiService, {
    required void Function(String route) onDeepLink,
  }) : _onDeepLink = onDeepLink;

  /// Initialize push notifications: request permissions, get token, register.
  Future<void> initialize() async {
    final messaging = FirebaseMessaging.instance;

    // Request permission (iOS shows a dialog, Android auto-grants)
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('[Push] Permission denied');
      return;
    }

    // Get FCM token
    final token = await messaging.getToken();
    if (token != null) {
      _currentToken = token;
      await _registerToken(token);
    }

    // Listen for token refreshes
    messaging.onTokenRefresh.listen((newToken) {
      _currentToken = newToken;
      _registerToken(newToken);
    });

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Handle taps while the app is backgrounded (resumed from tray).
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // Handle the tap that cold-started the app from a terminated state.
    // This must run AFTER the router is mounted; the callback sets a Riverpod
    // provider which AsideApp observes and routes on the next frame, so the
    // timing self-corrects even if initialize() runs before the first build.
    final initial = await messaging.getInitialMessage();
    if (initial != null) {
      _handleNotificationTap(initial);
    }

    debugPrint('[Push] FCM Token: $token');
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
    // Foreground notifications are NOT auto-displayed.
    // For now, we don't show them (the user is already in the app).
    // TODO: Show in-app banner for new posts, suppress for open conversations.
  }

  /// Unregister the token on logout.
  Future<void> unregister() async {
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
