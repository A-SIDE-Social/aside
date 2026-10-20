import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/services/voice_caption_service.dart';
import '../providers/api_provider.dart';

String voiceDuration(int milliseconds) {
  final seconds = (milliseconds / 1000).ceil();
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class VoiceCaptionPlayer extends ConsumerStatefulWidget {
  final String? postId;
  final String? localPath;
  final int durationMs;
  const VoiceCaptionPlayer(
      {super.key, this.postId, this.localPath, required this.durationMs})
      : assert(postId != null || localPath != null);
  @override
  ConsumerState<VoiceCaptionPlayer> createState() => _VoiceCaptionPlayerState();
}

class _VoiceCaptionPlayerState extends ConsumerState<VoiceCaptionPlayer>
    with WidgetsBindingObserver {
  static _VoiceCaptionPlayerState? _active;
  VoicePlayback? _player;
  StreamSubscription<bool>? _subscription;
  File? _cache;
  bool _playing = false, _busy = false, _failed = false;
  bool _visible = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    if (!_visible) unawaited(_pause());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_pause());
  }

  Future<void> _pause() async {
    if (_active == this) _active = null;
    try {
      await _player?.pause();
    } catch (_) {
      // An interrupted native player may already be stopped.
    }
    if (mounted) setState(() => _playing = false);
  }

  bool get _canPlay =>
      mounted &&
      _visible &&
      _active == this &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  Future<void> _playbackFailed() async {
    await _pause();
    if (mounted) setState(() => _failed = true);
  }

  Future<void> _toggle() async {
    if (_busy) return;
    if (_playing) {
      await _pause();
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      if (_active != this) await _active?._pause();
      _active = this;
      if (_player == null) {
        String? path = widget.localPath ?? _cache?.path;
        if (path == null) {
          final bytes = await ref
              .read(apiServiceProvider)
              .downloadVoiceCaption(widget.postId!);
          final file = await cacheVoiceCaption(bytes);
          if (!mounted) {
            await file.delete();
            return;
          }
          _cache = file;
          path = file.path;
        }
        if (!mounted) return;
        final player = ref.read(voicePlaybackFactoryProvider)();
        _player = player;
        _subscription = player.playing.listen((playing) {
          if (mounted) setState(() => _playing = playing);
        }, onError: (Object _) => unawaited(_playbackFailed()));
        await player.load(path);
      }
      if (_canPlay) {
        await _player!.play();
        if (_canPlay) {
          setState(() => _playing = true);
        } else {
          await _pause();
        }
      }
    } catch (_) {
      await _subscription?.cancel();
      try {
        await _player?.dispose();
      } catch (_) {}
      _player = null;
      if (mounted) {
        setState(() {
          _failed = true;
          _playing = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_active == this) _active = null;
    unawaited(_subscription?.cancel());
    final player = _player;
    final cache = _cache;
    unawaited(() async {
      try {
        await player?.dispose();
      } catch (_) {}
      try {
        if (cache != null && await cache.exists()) await cache.delete();
      } on FileSystemException catch (_) {}
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(children: [
        IconButton(
          tooltip: _playing ? 'Pause voice caption' : 'Play voice caption',
          onPressed: _busy ? null : _toggle,
          icon: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        Expanded(
            child: Text(_failed
                ? 'Couldn’t play. Tap to retry.'
                : 'Voice caption · ${voiceDuration(widget.durationMs)}')),
      ]);
}
