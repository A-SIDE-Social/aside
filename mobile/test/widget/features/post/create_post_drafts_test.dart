import 'dart:async';
import 'dart:io';

import 'package:aside/features/post/create_post_screen.dart';
import 'package:aside/core/services/voice_caption_service.dart';
import 'package:aside/models/user.dart';
import 'package:aside/models/post_draft.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:aside/providers/draft_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fixtures.dart';
import '../../../helpers/mocks.dart';
import '../../../helpers/voice_fakes.dart';

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        status: AuthStatus.authenticated,
        user: User.fromJson(userJson(id: 'composer-user')),
      );
}

class _TextDraftStorage extends DraftStorage {
  _TextDraftStorage(Directory directory)
      : super(directory: () async => directory);
  // File preservation and cleanup have separate unit coverage.
  @override
  Future<PostDraft> preserveMedia(String owner, PostDraft draft) async => draft;
  @override
  Future<void> removeMedia(String owner, String id) async {}
  bool failWrites = false;
  Completer<void>? pendingWrite;
  @override
  Future<void> write(String owner, List<PostDraft> drafts) async {
    await pendingWrite?.future;
    if (failWrites) throw const FileSystemException('Storage full');
    await super.write(owner, drafts);
  }
}

void main() {
  late Directory directory;
  late ProviderContainer container;
  late GoRouter router;
  late MockApiService api;
  late _TextDraftStorage storage;
  late FakeVoiceRecorder recorder;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('aside-composer-');
    api = MockApiService();
    recorder = FakeVoiceRecorder();
    storage = _TextDraftStorage(directory);
    when(() => api.getLists()).thenAnswer((_) async => []);
    when(() => api.getFeed(
          before: any(named: 'before'),
          groupId: any(named: 'groupId'),
        )).thenAnswer((_) async => {'posts': <dynamic>[]});
    container = ProviderContainer(overrides: [
      authProvider.overrideWith(_Auth.new),
      apiServiceProvider.overrideWithValue(api),
      draftStorageProvider.overrideWithValue(storage),
      voiceRecorderFactoryProvider.overrideWithValue(() => recorder),
    ]);
    router = GoRouter(routes: [
      GoRoute(
          path: '/', builder: (_, __) => const Scaffold(body: Text('Home'))),
      GoRoute(path: '/post/new', builder: (_, __) => const CreatePostScreen()),
    ]);
  });

  tearDown(() {
    router.dispose();
    container.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    router.push('/post/new');
    await tester.pumpAndSettle();
  }

  Future<void> enterText(WidgetTester tester, String text) async {
    await tester.tap(find.text('Text post'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, text);
  }

  testWidgets('new text posts request sentence capitalization', (tester) async {
    await open(tester);
    await enterText(tester, 'A thought');
    expect(
      tester.widget<TextField>(find.byType(TextField).first).textCapitalization,
      TextCapitalization.sentences,
    );
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
  });

  testWidgets('photo captions request sentence capitalization', (tester) async {
    final draft = PostDraft(
      id: 'photo-caption',
      caption: 'Photo draft',
      isTextPost: false,
      localFilePaths: [File('assets/images/logo_mark.png').absolute.path],
      videoFlags: const [false],
      completedMedia: const [],
      nextFileIndex: 0,
      createdAt: DateTime(2026),
    );
    SharedPreferences.setMockInitialValues({
      'post_drafts:composer-user': [draft.encode()],
    });
    await open(tester);
    await tester.tap(find.text('You have 1 unfinished post. Tap to resume.'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo draft'));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Write a caption...');
    expect(tester.widget<TextField>(field).textCapitalization,
        TextCapitalization.sentences);
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
  });

  testWidgets('close saves immediately and reopening resumes the same draft',
      (tester) async {
    await open(tester);
    expect(find.text('Create a new post'), findsNothing);
    await enterText(tester, 'An unfinished thought');
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(
        container.read(draftProvider).single.caption, 'An unfinished thought');
    router.push('/post/new');
    await tester.pumpAndSettle();
    await tester.tap(find.text('You have 1 unfinished post. Tap to resume.'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('An unfinished thought'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'An unfinished thought');
    await tester.enterText(find.byType(TextField).first, 'A revised thought');
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(container.read(draftProvider), hasLength(1));
    expect(container.read(draftProvider).single.caption, 'A revised thought');
  });

  testWidgets('resumed photo draft uploads its voice caption when shared',
      (tester) async {
    final voice = File('${directory.path}/voice.m4a')
      ..writeAsBytesSync([1, 2, 3]);
    final draft = PostDraft(
      id: 'voice-photo',
      caption: 'A memory',
      isTextPost: false,
      localFilePaths: [File('assets/images/logo_mark.png').absolute.path],
      videoFlags: const [false],
      completedMedia: const [
        {'key': 'photo.jpg', 'media_type': 'photo', 'position': 0}
      ],
      nextFileIndex: 1,
      createdAt: DateTime(2026),
      voiceCaptionPath: voice.path,
      voiceCaptionDurationMs: 12000,
    );
    SharedPreferences.setMockInitialValues({
      'post_drafts:composer-user': [draft.encode()]
    });
    when(() => api.uploadVoiceCaption(any(), any()))
        .thenAnswer((_) async => 'voice-id');
    when(() => api.createPost(
            caption: any(named: 'caption'),
            media: any(named: 'media'),
            groupIds: any(named: 'groupIds'),
            hideAfter24h: any(named: 'hideAfter24h'),
            voiceCaptionId: any(named: 'voiceCaptionId')))
        .thenAnswer((_) async => {});
    await open(tester);
    await tester.tap(find.text('You have 1 unfinished post. Tap to resume.'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A memory'));
    await tester.pumpAndSettle();
    expect(find.text('Voice caption · 0:12'), findsOneWidget);
    await tester.tap(find.text('Share'));
    // The recording is read from a real file. Pump frames between IO turns
    // so draft cleanup and the subsequent feed refresh can both complete.
    for (var attempt = 0;
        attempt < 30 && find.text('Home').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
    verify(() => api.uploadVoiceCaption([1, 2, 3], 12000)).called(1);
    verify(() => api.createPost(
        caption: 'A memory',
        media: any(named: 'media'),
        groupIds: null,
        hideAfter24h: false,
        voiceCaptionId: 'voice-id')).called(1);
    expect(find.text('Home'), findsOneWidget);
    expect(container.read(draftProvider), isEmpty);
  });

  testWidgets('recording blocks share and Back without losing the composer',
      (tester) async {
    final draft = PostDraft(
      id: 'record-photo',
      caption: 'A photo',
      isTextPost: false,
      localFilePaths: [File('assets/images/logo_mark.png').absolute.path],
      videoFlags: const [false],
      completedMedia: const [],
      nextFileIndex: 0,
      createdAt: DateTime(2026),
    );
    SharedPreferences.setMockInitialValues({
      'post_drafts:composer-user': [draft.encode()]
    });
    await open(tester);
    await tester.tap(find.text('You have 1 unfinished post. Tap to resume.'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A photo'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add voice caption'));
    await tester.tap(find.text('Add voice caption'));
    await tester.pump();
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Share'))
            .onPressed,
        isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('New Post'), findsOneWidget);
    expect(recorder.stops, 0);
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();
    await tester.tap(find.byTooltip('Remove voice caption'));
    await tester.pump();
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Share'))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('backgrounding saves text and expiry without leaving the editor',
      (tester) async {
    await open(tester);
    await enterText(tester, 'Keep this for later');
    await tester.tap(find.byType(Switch).first);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    final draft = container.read(draftProvider).single;
    expect(draft.caption, 'Keep this for later');
    expect(draft.hideAfter24h, true);
    expect(find.text('New Text Post'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('system Back saves a draft', (tester) async {
    await open(tester);
    await enterText(tester, 'Saved by Back');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(container.read(draftProvider).single.caption, 'Saved by Back');
  });

  for (final textScale in [1.0, 2.0]) {
    testWidgets('draft status never moves the editor at text scale $textScale',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, textScale: textScale);
      await tester.tap(find.text('Text post'));
      await tester.pumpAndSettle();
      final field = find.byType(TextField).first;
      final position = tester.getTopLeft(field);
      void expectStable(String status) {
        expect(find.text(status).hitTestable(), findsOneWidget);
        expect(tester.getTopLeft(field), position);
      }

      expectStable('Drafts save on this device');
      storage.pendingWrite = Completer<void>();
      await tester.enterText(field, 'First thought');
      await tester.pump(const Duration(milliseconds: 800));
      expectStable('Saving draft…');
      storage.pendingWrite!.complete();
      storage.pendingWrite = null;
      await tester.pumpAndSettle();
      expectStable('Draft saved on this device');

      storage.failWrites = true;
      await tester.enterText(field, 'Revised thought');
      await tester.pump();
      expectStable('Saving draft…');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expectStable('Draft couldn’t be saved. Try again.');

      storage.failWrites = false;
      await tester.enterText(field, 'Ready for later');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expectStable('Draft saved on this device');

      await tester.enterText(field, '');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expectStable('Drafts save on this device');
    });
  }

  testWidgets('a failed save keeps the editor open for a retry',
      (tester) async {
    await open(tester);
    await enterText(tester, 'Don’t lose this');
    storage.failWrites = true;
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.text('New Text Post'), findsOneWidget);
    expect(container.read(draftProvider), isEmpty);
    storage.failWrites = false;
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(container.read(draftProvider).single.caption, 'Don’t lose this');
  });

  testWidgets('cancelling an empty composer creates no draft', (tester) async {
    await open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(container.read(draftProvider), isEmpty);
  });

  testWidgets('new-post action is only visible before opening the draft picker',
      (tester) async {
    final draft = PostDraft(
      id: 'saved',
      caption: 'For later',
      isTextPost: true,
      localFilePaths: const [],
      videoFlags: const [],
      completedMedia: const [],
      nextFileIndex: 0,
      createdAt: DateTime(2026),
    );
    SharedPreferences.setMockInitialValues({
      'post_drafts:composer-user': [draft.encode()],
    });
    await open(tester);
    expect(find.text('Create a new post'), findsOneWidget);
    await tester.tap(find.text('Create a new post'));
    await tester.pumpAndSettle();
    expect(find.text('Text post'), findsOneWidget);
    expect(find.text('Create a new post'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('publishing removes the autosaved draft without recreating it',
      (tester) async {
    when(() => api.createPost(
          caption: any(named: 'caption'),
          media: any(named: 'media'),
          groupIds: any(named: 'groupIds'),
          hideAfter24h: any(named: 'hideAfter24h'),
          voiceCaptionId: any(named: 'voiceCaptionId'),
        )).thenAnswer((_) async => {'post': <String, dynamic>{}});
    await open(tester);
    await enterText(tester, 'Ready to share');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(container.read(draftProvider), hasLength(1));
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(container.read(draftProvider), isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(container.read(draftProvider), isEmpty);
    verify(() => api.createPost(
          caption: 'Ready to share',
          media: null,
          groupIds: null,
          hideAfter24h: false,
          voiceCaptionId: null,
        )).called(1);
  });
}
