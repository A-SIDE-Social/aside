import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/services/revenuecat_service.dart';
import 'core/services/speech_service.dart';

/// Top-level background message handler (must be top-level function).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Widget update is handled natively in AppDelegate via didReceiveRemoteNotification
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Widen Flutter's in-memory decoded image cache so routine backgrounding
  // (which triggers iOS memory pressure) doesn't wipe the working set.
  // Default is 100 MB / 1000 entries; bumped to ~250 MB / 2000.
  PaintingBinding.instance.imageCache
    ..maximumSize = 2000
    ..maximumSizeBytes = 250 * 1024 * 1024;

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await RevenueCatService.initialize();
  await SpeechService.instance.init();

  runApp(
    const ProviderScope(
      child: AsideApp(),
    ),
  );
}
