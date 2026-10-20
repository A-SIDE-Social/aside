import 'dart:async';
import 'package:aside/core/services/voice_caption_service.dart';
import 'package:aside/widgets/voice_caption_editor.dart';
import 'package:aside/widgets/voice_caption_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../helpers/voice_fakes.dart';

void main() {
  late FakeVoiceRecorder recorder;
  late List<FakeVoicePlayback> players;
  VoiceRecording? saved;
  bool recording = false;
  setUp(() {
    recorder = FakeVoiceRecorder();
    players = [];
    saved = null;
    recording = false;
  });
  Future<void> open(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(ProviderScope(overrides: [
      voiceRecorderFactoryProvider.overrideWithValue(() => recorder),
      voicePlaybackFactoryProvider.overrideWithValue(() {
        final player = FakeVoicePlayback();
        players.add(player);
        return player;
      }),
    ], child: MaterialApp(home: Scaffold(body: child))));
    await tester.pump();
  }

  Widget editor() => VoiceCaptionEditor(
      value: saved,
      onChanged: (value) => saved = value,
      onRecordingChanged: (value) => recording = value);
  const player =
      VoiceCaptionPlayer(localPath: '/recording.m4a', durationMs: 12000);

  testWidgets('microphone and playback stay untouched until tapped',
      (tester) async {
    await open(tester, Column(children: [editor(), player]));
    expect(recorder.starts, 0);
    expect(players, isEmpty);
    expect(find.text('Voice caption · 0:12'), findsOneWidget);
    await tester.tap(find.text('Add voice caption'));
    await tester.pump();
    expect(recording, true);
    expect(recorder.starts, 1);
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();
    expect(saved?.durationMs, 12000);
    expect(recording, false);
    expect(recorder.disposals, 1);
  });
  testWidgets('denied microphone access is recoverable', (tester) async {
    recorder.permission = false;
    await open(tester, editor());
    await tester.tap(find.text('Add voice caption'));
    await tester.pump();
    expect(find.text('Allow microphone access in Settings to record.'),
        findsOneWidget);
    expect(recorder.starts, 0);
    expect(recording, false);
    recorder.permission = true;
    await tester.tap(find.text('Add voice caption'));
    await tester.pump();
    expect(recorder.starts, 1);
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();
  });
  testWidgets('recording stops automatically at one minute', (tester) async {
    await open(tester, editor());
    await tester.tap(find.text('Add voice caption'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(recorder.stops, 1);
    expect(saved, isNotNull);
    expect(recording, false);
  });
  testWidgets('backgrounding stops recording and saves the result',
      (tester) async {
    await open(tester, editor());
    await tester.tap(find.text('Add voice caption'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(recorder.stops, 1);
    expect(saved, isNotNull);
    expect(recording, false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  testWidgets('leaving while permission is pending never starts recording',
      (tester) async {
    recorder.pendingPermission = Completer<bool>();
    await open(tester, editor());
    await tester.tap(find.text('Add voice caption'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    recorder.pendingPermission!.complete(true);
    await tester.pump();
    expect(recorder.starts, 0);
    expect(recorder.disposals, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed recording can be retried', (tester) async {
    recorder.failStop = true;
    await open(tester, editor());
    await tester.tap(find.text('Add voice caption'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();
    expect(find.text('Couldn’t save the recording. Please try again.'),
        findsOneWidget);
    expect(recording, false);
    expect(find.text('Add voice caption'), findsOneWidget);
  });
  testWidgets('playback is tap-only, pauses, and reuses its player',
      (tester) async {
    await open(tester, player);
    await tester.tap(find.byTooltip('Play voice caption'));
    await tester.pump();
    expect(players.single.loads, 1);
    expect(players.single.plays, 1);
    await tester.tap(find.byTooltip('Pause voice caption'));
    await tester.pump();
    expect(players.single.pauses, 1);
    await tester.tap(find.byTooltip('Play voice caption'));
    await tester.pump();
    expect(players.single.loads, 1);
    expect(players.single.plays, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(players.single.disposals, 1);
  });
  testWidgets('starting another caption pauses the previous one',
      (tester) async {
    await open(tester, const Column(children: [player, player]));
    await tester.tap(find.byTooltip('Play voice caption').first);
    await tester.pump();
    await tester.tap(find.byTooltip('Play voice caption').last);
    await tester.pump();
    expect(players.first.pauses, 1);
    expect(players.last.plays, 1);
    expect(find.byTooltip('Pause voice caption'), findsOneWidget);
  });
  testWidgets('asynchronous playback errors show retry', (tester) async {
    await open(tester, player);
    await tester.tap(find.byTooltip('Play voice caption'));
    await tester.pump();
    players.single.states.addError(StateError('Playback interrupted'));
    await tester.pump();
    expect(find.text('Couldn’t play. Tap to retry.'), findsOneWidget);
    expect(find.byTooltip('Play voice caption'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('audio loaded while backgrounded never starts playing',
      (tester) async {
    // Start paused, then delay a subsequent load through a dedicated factory.
    final pending = Completer<void>();
    final delayed = FakeVoicePlayback()..pendingLoad = pending;
    await tester.pumpWidget(ProviderScope(overrides: [
      voicePlaybackFactoryProvider.overrideWithValue(() => delayed),
    ], child: const MaterialApp(home: Scaffold(body: player))));
    await tester.tap(find.byTooltip('Play voice caption'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    pending.complete();
    await tester.pump();
    expect(delayed.plays, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  testWidgets('voice caption can be removed', (tester) async {
    saved = const VoiceRecording('/recording.m4a', 5000);
    await open(tester, editor());
    await tester.tap(find.byTooltip('Remove voice caption'));
    await tester.pump();
    expect(saved, isNull);
    expect(players, isEmpty);
  });
}
