import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/services/voice_caption_service.dart';
import 'voice_caption_player.dart';

class VoiceCaptionEditor extends ConsumerStatefulWidget {
  final VoiceRecording? value;
  final bool enabled;
  final ValueChanged<VoiceRecording?> onChanged;
  final ValueChanged<bool> onRecordingChanged;
  const VoiceCaptionEditor(
      {super.key,
      required this.value,
      required this.onChanged,
      required this.onRecordingChanged,
      this.enabled = true});
  @override
  ConsumerState<VoiceCaptionEditor> createState() => _VoiceCaptionEditorState();
}

class _VoiceCaptionEditorState extends ConsumerState<VoiceCaptionEditor>
    with WidgetsBindingObserver {
  VoiceRecorder? _recorder;
  Timer? _timer;
  Timer? _limitTimer;
  final _elapsed = Stopwatch();
  bool _recording = false, _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onRecordingChanged(true);
    try {
      final recorder = ref.read(voiceRecorderFactoryProvider)();
      _recorder = recorder;
      if (!await recorder.hasPermission()) {
        if (mounted) {
          setState(
              () => _error = 'Allow microphone access in Settings to record.');
        }
        return;
      }
      if (!mounted || !_foreground) return;
      await recorder.start();
      if (!mounted || !_foreground) return;
      _elapsed
        ..reset()
        ..start();
      setState(() => _recording = true);
      widget.onRecordingChanged(true);
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) {
          setState(() {});
        }
      });
      _limitTimer =
          Timer(const Duration(seconds: 60), () => unawaited(_stop()));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Couldn’t record. Please try again.');
      }
    } finally {
      if (!_recording) {
        await _disposeRecorder();
        if (mounted) widget.onRecordingChanged(false);
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  Future<void> _disposeRecorder() async {
    final recorder = _recorder;
    _recorder = null;
    try {
      await recorder?.dispose();
    } catch (_) {
      // Keep native teardown failures out of the recording UI.
    }
  }

  Future<void> _stop() async {
    if (!_recording || _busy) return;
    _timer?.cancel();
    _limitTimer?.cancel();
    _elapsed.stop();
    setState(() => _busy = true);
    try {
      final result = await _recorder!.stop();
      if (result == null) throw StateError('Recording unavailable');
      if (mounted) {
        widget.onChanged(result);
      } else if (result.temporary) {
        try {
          await File(result.path).delete();
        } on FileSystemException catch (_) {}
      }
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = 'Couldn’t save the recording. Please try again.');
      }
    } finally {
      await _disposeRecorder();
      if (mounted) {
        setState(() {
          _recording = false;
          _busy = false;
        });
        widget.onRecordingChanged(false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _recording) unawaited(_stop());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _limitTimer?.cancel();
    // A pending start/stop owns teardown until its native operation returns.
    if (!_busy) unawaited(_disposeRecorder());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_recording)
          TextButton.icon(
              onPressed: _busy ? null : _stop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(
                  'Stop · ${voiceDuration(_elapsed.elapsedMilliseconds)} / 1:00'))
        else if (widget.value case final recording?)
          Row(children: [
            Expanded(
                child: VoiceCaptionPlayer(
                    key: ValueKey(recording.path),
                    localPath: recording.path,
                    durationMs: recording.durationMs)),
            IconButton(
                tooltip: 'Remove voice caption',
                onPressed: !widget.enabled || _busy
                    ? null
                    : () => widget.onChanged(null),
                icon: const Icon(Icons.close)),
          ])
        else
          TextButton.icon(
              onPressed: !widget.enabled || _busy ? null : _start,
              icon: const Icon(Icons.mic_none),
              label: Text(_busy ? 'Opening microphone…' : 'Add voice caption')),
        if (widget.value == null && !_recording)
          const Text('Up to 1 minute · Shared with this post’s audience'),
        if (_error != null)
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]);
}
