import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// On-device speech-to-text using Apple SpeechAnalyzer (iOS 26+).
/// Audio never leaves the device.
class SpeechService {
  SpeechService._();
  static final SpeechService instance = SpeechService._();

  static const _methodChannel = MethodChannel('com.lab1908.instadamn/speech');
  static const _eventChannel =
      EventChannel('com.lab1908.instadamn/speech_events');

  bool _available = false;
  bool get isAvailable => _available;

  bool _listening = false;
  bool get isListening => _listening;

  void _log(String msg) {
    if (kDebugMode) debugPrint('[SpeechService] $msg');
  }

  /// Check if on-device speech recognition is available.
  /// Returns false on Android, iOS < 26, or if SpeechAnalyzer is unavailable.
  Future<void> init() async {
    try {
      _available =
          await _methodChannel.invokeMethod<bool>('isAvailable') ?? false;
      _log('init: available=$_available');
    } catch (e) {
      _available = false;
      _log('init: not available ($e)');
    }
  }

  /// Stream of partial and final transcription results.
  Stream<SpeechResult> get transcriptionStream =>
      _eventChannel.receiveBroadcastStream().map((event) {
        final map = Map<String, dynamic>.from(event as Map);
        return SpeechResult(
          text: map['text'] as String? ?? '',
          isFinal: map['isFinal'] as bool? ?? false,
          durationSeconds: map['durationSeconds'] as int?,
          timedOut: map['timedOut'] as bool? ?? false,
        );
      });

  /// Allow provider to reset listening state (e.g. after native-side timeout).
  void setListening(bool value) => _listening = value;

  /// Start listening. Returns null on success, or an error message on failure.
  Future<String?> startListening() async {
    if (!_available) {
      _log('startListening: not available');
      return 'Speech recognition not available';
    }
    if (_listening) {
      _log('startListening: already listening');
      return null; // already going
    }

    try {
      await _methodChannel.invokeMethod<bool>('startListening');
      _listening = true;
      _log('startListening: OK');
      return null;
    } on PlatformException catch (e) {
      _log('startListening: error ${e.code} ${e.message}');
      _listening = false;
      return e.message ?? 'Speech recognition failed';
    }
  }

  /// Stop listening and finalize transcription.
  Future<void> stopListening() async {
    if (!_listening) return;

    try {
      await _methodChannel.invokeMethod<void>('stopListening');
      _listening = false;
      _log('stopListening: OK');
    } on PlatformException catch (e) {
      _log('stopListening: error ${e.code} ${e.message}');
      _listening = false;
    }
  }

  /// Cancel listening without finalizing.
  Future<void> cancelListening() async {
    if (!_listening) return;

    try {
      await _methodChannel.invokeMethod<void>('cancelListening');
      _listening = false;
      _log('cancelListening: OK');
    } on PlatformException catch (e) {
      _log('cancelListening: error ${e.code} ${e.message}');
      _listening = false;
    }
  }
}

/// A speech transcription result (partial or final).
class SpeechResult {
  const SpeechResult({
    required this.text,
    required this.isFinal,
    this.durationSeconds,
    this.timedOut = false,
  });

  /// The transcribed text (partial or complete).
  final String text;

  /// Whether this is the final result.
  final bool isFinal;

  /// Duration of the recording in seconds (only on final results).
  final int? durationSeconds;

  /// Whether this result was triggered by silence timeout.
  final bool timedOut;
}
