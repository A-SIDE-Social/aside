import 'package:flutter_test/flutter_test.dart';

import 'package:aside/core/services/speech_service.dart';

void main() {
  group('SpeechResult', () {
    test('constructs with required fields', () {
      const result = SpeechResult(text: 'hello', isFinal: false);
      expect(result.text, 'hello');
      expect(result.isFinal, false);
      expect(result.durationSeconds, isNull);
      expect(result.timedOut, false);
    });

    test('constructs with all fields', () {
      const result = SpeechResult(
        text: 'hello world',
        isFinal: true,
        durationSeconds: 5,
        timedOut: true,
      );
      expect(result.text, 'hello world');
      expect(result.isFinal, true);
      expect(result.durationSeconds, 5);
      expect(result.timedOut, true);
    });

    test('timedOut defaults to false', () {
      const result = SpeechResult(text: '', isFinal: true);
      expect(result.timedOut, false);
    });
  });

  group('SpeechService', () {
    test('singleton instance is consistent', () {
      final a = SpeechService.instance;
      final b = SpeechService.instance;
      expect(identical(a, b), true);
    });

    test('isAvailable defaults to false before init', () {
      expect(SpeechService.instance.isAvailable, false);
    });

    test('isListening defaults to false', () {
      expect(SpeechService.instance.isListening, false);
    });

    test('setListening updates state', () {
      final service = SpeechService.instance;
      expect(service.isListening, false);
      service.setListening(true);
      expect(service.isListening, true);
      service.setListening(false);
      expect(service.isListening, false);
    });

    test('startListening returns error when not available', () async {
      final error = await SpeechService.instance.startListening();
      expect(error, 'Speech recognition not available');
    });

    test('stopListening is no-op when not listening', () async {
      // Should not throw
      await SpeechService.instance.stopListening();
      expect(SpeechService.instance.isListening, false);
    });

    test('cancelListening is no-op when not listening', () async {
      // Should not throw
      await SpeechService.instance.cancelListening();
      expect(SpeechService.instance.isListening, false);
    });
  });
}
