import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/speech_service.dart';

enum SpeechStatus { idle, listening, error }

class SpeechStateData {
  const SpeechStateData({
    this.status = SpeechStatus.idle,
    this.transcript = '',
    this.errorMessage,
    this.sessionId,
  });

  final SpeechStatus status;
  final String transcript;
  final String? errorMessage;

  /// Monotonic id minted at the start of each listening session, cleared
  /// when listening stops or is cancelled. Consumers capture the id when
  /// they call [startListening] and ignore subsequent stream updates
  /// whose `sessionId` doesn't match theirs. Prevents transcript leakage
  /// across [SpeechInputButton] instances on different screens — the
  /// original bug was that a button in the DM composer would read stale
  /// transcript from a finished dictation session on the post composer
  /// and write it into the new text field.
  final int? sessionId;

  SpeechStateData copyWith({
    SpeechStatus? status,
    String? transcript,
    String? errorMessage,
    int? sessionId,
  }) {
    return SpeechStateData(
      status: status ?? this.status,
      transcript: transcript ?? this.transcript,
      errorMessage: errorMessage,
      sessionId: sessionId ?? this.sessionId,
    );
  }
}

void _log(String msg) {
  if (kDebugMode) debugPrint('[SpeechProvider] $msg');
}

class SpeechNotifier extends Notifier<SpeechStateData> {
  StreamSubscription<SpeechResult>? _subscription;
  String _finalizedText = '';

  @override
  SpeechStateData build() {
    ref.onDispose(() {
      _subscription?.cancel();
    });
    return const SpeechStateData();
  }

  Future<bool> startListening() async {
    final service = SpeechService.instance;
    if (!service.isAvailable) {
      _log('startListening: not available');
      state = state.copyWith(
        status: SpeechStatus.error,
        errorMessage: 'Speech recognition not available',
      );
      return false;
    }

    // Subscribe to transcription events before starting
    _subscription?.cancel();
    _finalizedText = '';
    _subscription = service.transcriptionStream.listen(
      (result) {
        // Silence timeout — native side already cleaned up
        if (result.timedOut) {
          _log('silence timeout');
          _subscription?.cancel();
          _subscription = null;
          service.setListening(false);
          // Clear sessionId so no button picks up the trailing transcript.
          state = SpeechStateData(
            status: SpeechStatus.idle,
            transcript:
                _finalizedText.isNotEmpty ? _finalizedText : state.transcript,
            sessionId: null,
          );
          _finalizedText = '';
          return;
        }

        if (result.text.isNotEmpty) {
          if (result.isFinal) {
            // Accumulate finalized chunks — SpeechAnalyzer sends isFinal
            // per sentence/segment, not just at end of session
            _finalizedText =
                '$_finalizedText${_finalizedText.isEmpty ? '' : ' '}${result.text}';
            _log('finalized chunk: ${result.text}');
          }
          state = state.copyWith(
            transcript: result.isFinal
                ? _finalizedText
                : '$_finalizedText${_finalizedText.isEmpty ? '' : ' '}${result.text}',
            status: SpeechStatus.listening,
          );
        }
      },
      onError: (e) {
        _log('stream error: $e');
        state = state.copyWith(
          status: SpeechStatus.error,
          errorMessage: 'Speech recognition error',
        );
        _subscription?.cancel();
        _subscription = null;
      },
    );

    final error = await service.startListening();
    if (error == null) {
      // Mint a fresh session id. Microseconds-since-epoch is plenty
      // unique for hand-driven dictation sessions and collision-free
      // across the lifetime of a running app.
      state = SpeechStateData(
        status: SpeechStatus.listening,
        transcript: '',
        sessionId: DateTime.now().microsecondsSinceEpoch,
      );
      _log('listening started');
      return true;
    } else {
      _subscription?.cancel();
      _subscription = null;
      state = state.copyWith(
        status: SpeechStatus.error,
        errorMessage: error,
      );
      _log('start failed: $error');
      return false;
    }
  }

  Future<void> stopListening() async {
    _subscription?.cancel();
    _subscription = null;
    await SpeechService.instance.stopListening();
    // Clear sessionId to close the door on any consumer that might
    // still be watching the stream. The transcript itself stays
    // available on the state so the originating button's last build
    // under isListening=true already wrote the final text to its
    // controller — nothing else needs to consume it post-stop.
    state = SpeechStateData(
      status: SpeechStatus.idle,
      transcript: _finalizedText.isNotEmpty ? _finalizedText : state.transcript,
      sessionId: null,
    );
    _finalizedText = '';
    _log('stopped');
  }

  Future<void> cancelListening() async {
    _subscription?.cancel();
    _subscription = null;
    _finalizedText = '';
    await SpeechService.instance.cancelListening();
    state = const SpeechStateData();
    _log('cancelled');
  }

  void clearError() {
    if (state.status == SpeechStatus.error) {
      state = const SpeechStateData();
    }
  }
}

final speechProvider =
    NotifierProvider<SpeechNotifier, SpeechStateData>(SpeechNotifier.new);
