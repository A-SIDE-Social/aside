import 'dart:convert';
import 'dart:io';

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

  group('stripVideoMetadata', () {
    Future<dynamic> Function(MethodCall) respondToCompress(
        Future<dynamic> Function() compress) {
      return (call) async {
        if (call.method == 'compressVideo') return compress();
        return null;
      };
    }

    test('returns the processed copy', () async {
      messenger.setMockMethodCallHandler(
          channel,
          respondToCompress(
              () async => jsonEncode({'path': '/processed/clean.mp4'})));
      final result = await stripVideoMetadata('/original/recorded.mp4');
      expect(result.path, '/processed/clean.mp4');
    });

    test('never falls back to the original when processing fails', () async {
      messenger.setMockMethodCallHandler(
          channel,
          respondToCompress(
              () async => throw PlatformException(code: 'private-path-fixture')));
      await expectLater(
          stripVideoMetadata('/original/recorded.mp4'),
          throwsA(isA<PostVideoValidationException>().having((e) => e.message,
              'message', isNot(contains('private-path-fixture')))));
    });

    test('never falls back to the original when no file is produced', () async {
      messenger.setMockMethodCallHandler(
          channel, respondToCompress(() async => null));
      await expectLater(stripVideoMetadata('/original/recorded.mp4'),
          throwsA(isA<PostVideoValidationException>()));
    });
  });

  group('validatePostVideoSize', () {
    late Directory directory;
    late File file;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('video_size_test');
      file = File('${directory.path}/fixture.mp4');
      await file.writeAsBytes(List<int>.filled(10, 0));
    });
    tearDown(() => directory.delete(recursive: true));

    test('allows a file at the exact limit', () async {
      await validatePostVideoSize(file, maxBytes: 10);
    });

    test('rejects a file over the limit', () async {
      await expectLater(validatePostVideoSize(file, maxBytes: 9),
          throwsA(isA<PostVideoValidationException>()));
    });
  });
}
