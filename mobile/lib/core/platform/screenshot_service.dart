// Dart wrapper around the screenshot detector platform plugin.
//
// iOS: subscribes to UIApplication.userDidTakeScreenshotNotification
// (see ios/Runner/ScreenshotPlugin.swift). Each notification produces
// a void event on [onScreenshot].
//
// Android: stub plugin; the stream never emits in v1.
//
// Subscribers (today: AsideApp at the app root) show a slide-up
// privacy banner each time the stream fires. There is no API to
// block screenshots; this is gentle awareness, not enforcement.

import 'package:flutter/services.dart';

class ScreenshotService {
  static final ScreenshotService instance = ScreenshotService._();
  ScreenshotService._();

  static const _eventChannel = EventChannel(
    'com.lab1908.instadamn/screenshot_events',
  );

  /// Fires once per screenshot taken while the app is foreground.
  /// Single broadcast stream — multiple listeners share the same
  /// event channel subscription.
  Stream<void> get onScreenshot =>
      // The platform side emits an empty Map for forward-compat;
      // we discard the payload and surface only the signal.
      _eventChannel.receiveBroadcastStream().map<void>((_) {});
}
