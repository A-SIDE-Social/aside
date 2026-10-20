import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

class VoiceRecording {
  final String path;
  final int durationMs;
  final bool temporary;
  const VoiceRecording(this.path, this.durationMs, {this.temporary = false});
}

abstract class VoiceRecorder {
  Future<bool> hasPermission();
  Future<void> start();
  Future<VoiceRecording?> stop();
  Future<void> dispose();
}

class DeviceVoiceRecorder implements VoiceRecorder {
  final _recorder = AudioRecorder();
  final _elapsed = Stopwatch();
  bool _disposed = false;
  @override
  Future<bool> hasPermission() => _recorder.hasPermission();
  @override
  Future<void> start() async {
    final directory = await getTemporaryDirectory();
    await _recorder.start(
        const RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 64000,
            sampleRate: 44100,
            numChannels: 1),
        path: '${directory.path}/voice-${const Uuid().v4()}.m4a');
    _elapsed
      ..reset()
      ..start();
  }

  @override
  Future<VoiceRecording?> stop() async {
    _elapsed.stop();
    final path = await _recorder.stop();
    if (path == null) return null;
    return VoiceRecording(path, _elapsed.elapsedMilliseconds.clamp(1, 60000),
        temporary: true);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (await _recorder.isRecording()) await _recorder.cancel();
    await _recorder.dispose();
  }
}

abstract class VoicePlayback {
  Stream<bool> get playing;
  Future<void> load(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> dispose();
}

class DeviceVoicePlayback implements VoicePlayback {
  final _player = AudioPlayer();
  final _states = StreamController<bool>.broadcast();
  late final StreamSubscription<PlayerState> _stateSubscription;
  late final StreamSubscription<PlayerException> _errorSubscription;
  DeviceVoicePlayback() {
    _stateSubscription = _player.playerStateStream.listen((state) {
      _states.add(
          state.playing && state.processingState != ProcessingState.completed);
    });
    _errorSubscription = _player.errorStream.listen((error) {
      if (!_states.isClosed) _states.addError(error);
    });
  }
  @override
  Stream<bool> get playing => _states.stream;
  @override
  Future<void> load(String path) async {
    await _player.setFilePath(path);
  }

  @override
  Future<void> play() async {
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    // Completion is delivered by the state stream; don't block the button.
    unawaited(_player.play().catchError((Object error, StackTrace stack) {
      if (!_states.isClosed) _states.addError(error, stack);
    }));
  }

  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> dispose() async {
    await _stateSubscription.cancel();
    await _errorSubscription.cancel();
    await _player.dispose();
    await _states.close();
  }
}

final voiceRecorderFactoryProvider =
    Provider<VoiceRecorder Function()>((ref) => DeviceVoiceRecorder.new);
final voicePlaybackFactoryProvider =
    Provider<VoicePlayback Function()>((ref) => DeviceVoicePlayback.new);

Future<File> cacheVoiceCaption(List<int> bytes) async {
  if (bytes.isEmpty || bytes.length > 2097152) {
    throw const FormatException('Invalid voice caption');
  }
  final directory = await getTemporaryDirectory();
  return File('${directory.path}/voice-playback-${const Uuid().v4()}.m4a')
      .writeAsBytes(bytes, flush: true);
}
