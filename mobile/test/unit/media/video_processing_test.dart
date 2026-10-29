import 'dart:convert';

import 'package:aside/core/media/video_processing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('video_compress');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final duration in [30000, 180000]) {
    test(
        'allows a $duration ms post video, including the exact 3 minute boundary',
        () async {
      messenger.setMockMethodCallHandler(
          channel,
          (_) async =>
              jsonEncode({'path': 'fixture.mp4', 'duration': duration}));
      await validatePostVideoDuration('fixture.mp4');
    });
  }
  for (final duration in [180001, 240000, null, 0, -1, 'NaN', 'Infinity']) {
    test('rejects an over-limit or unverifiable video ($duration)', () async {
      messenger.setMockMethodCallHandler(
          channel,
          (_) async =>
              jsonEncode({'path': 'fixture.mp4', 'duration': duration}));
      await expectLater(validatePostVideoDuration('fixture.mp4'),
          throwsA(isA<PostVideoValidationException>()));
    });
  }
  test(
      'native metadata failure is not accepted and does not expose private error details',
      () async {
    messenger.setMockMethodCallHandler(channel,
        (_) async => throw PlatformException(code: 'private-path-fixture'));
    await expectLater(
        validatePostVideoDuration('fixture.mp4'),
        throwsA(isA<PostVideoValidationException>().having((e) => e.message,
            'message', isNot(contains('private-path-fixture')))));
  });
}
