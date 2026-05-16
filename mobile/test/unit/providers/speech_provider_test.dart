import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aside/providers/speech_provider.dart';

void main() {
  late ProviderContainer container;
  late SpeechNotifier notifier;

  setUp(() {
    container = ProviderContainer();
    notifier = container.read(speechProvider.notifier);
  });

  tearDown(() {
    container.dispose();
  });

  group('SpeechStateData', () {
    test('default state is idle with empty transcript', () {
      expect(container.read(speechProvider).status, SpeechStatus.idle);
      expect(container.read(speechProvider).transcript, '');
      expect(container.read(speechProvider).errorMessage, isNull);
    });

    test('copyWith replaces specified fields', () {
      const state = SpeechStateData();
      final updated = state.copyWith(
        status: SpeechStatus.listening,
        transcript: 'hello',
      );
      expect(updated.status, SpeechStatus.listening);
      expect(updated.transcript, 'hello');
      expect(updated.errorMessage, isNull);
    });

    test('copyWith clears errorMessage when not provided', () {
      const state = SpeechStateData(
        status: SpeechStatus.error,
        errorMessage: 'some error',
      );
      final updated = state.copyWith(status: SpeechStatus.idle);
      expect(updated.status, SpeechStatus.idle);
      expect(updated.errorMessage, isNull);
    });

    test('copyWith preserves fields when not specified', () {
      const state = SpeechStateData(
        status: SpeechStatus.listening,
        transcript: 'hello world',
      );
      final updated = state.copyWith(transcript: 'updated');
      expect(updated.status, SpeechStatus.listening);
      expect(updated.transcript, 'updated');
    });
  });

  group('SpeechNotifier', () {
    test('startListening returns false when service is unavailable', () async {
      // SpeechService.instance.isAvailable defaults to false in tests
      // (no native platform channel available)
      final result = await notifier.startListening();
      expect(result, false);
      expect(container.read(speechProvider).status, SpeechStatus.error);
      expect(container.read(speechProvider).errorMessage,
          'Speech recognition not available');
    });

    test('clearError resets to idle from error state', () {
      // Manually set error state via startListening (which will fail)
      notifier.startListening();
      // Wait for async to settle
      Future.delayed(const Duration(milliseconds: 100), () {
        expect(container.read(speechProvider).status, SpeechStatus.error);
        notifier.clearError();
        expect(container.read(speechProvider).status, SpeechStatus.idle);
        expect(container.read(speechProvider).transcript, '');
        expect(container.read(speechProvider).errorMessage, isNull);
      });
    });

    test('clearError is no-op when not in error state', () {
      expect(container.read(speechProvider).status, SpeechStatus.idle);
      notifier.clearError();
      expect(container.read(speechProvider).status, SpeechStatus.idle);
    });

    test('cancelListening resets to default state', () async {
      await notifier.cancelListening();
      expect(container.read(speechProvider).status, SpeechStatus.idle);
      expect(container.read(speechProvider).transcript, '');
      expect(container.read(speechProvider).errorMessage, isNull);
    });

    test('stopListening resets to idle', () async {
      await notifier.stopListening();
      expect(container.read(speechProvider).status, SpeechStatus.idle);
    });
  });
}
