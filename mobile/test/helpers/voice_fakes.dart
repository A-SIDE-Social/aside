import 'dart:async';
import 'package:aside/core/services/voice_caption_service.dart';

class FakeVoiceRecorder implements VoiceRecorder {
  bool permission = true;
  bool failStop = false;
  int starts = 0, stops = 0, disposals = 0;
  Completer<bool>? pendingPermission;
  VoiceRecording result = const VoiceRecording('/recording.m4a', 12000);
  @override
  Future<bool> hasPermission() async =>
      pendingPermission == null ? permission : await pendingPermission!.future;
  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<VoiceRecording?> stop() async {
    stops++;
    if (failStop) throw StateError('Recorder interrupted');
    return result;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class FakeVoicePlayback implements VoicePlayback {
  final states = StreamController<bool>.broadcast();
  int loads = 0, plays = 0, pauses = 0, disposals = 0;
  bool failLoad = false;
  Completer<void>? pendingLoad;
  @override
  Stream<bool> get playing => states.stream;
  @override
  Future<void> load(String path) async {
    loads++;
    await pendingLoad?.future;
    if (failLoad) throw StateError('Cannot decode audio');
  }

  @override
  Future<void> play() async {
    plays++;
    states.add(true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    states.add(false);
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}
