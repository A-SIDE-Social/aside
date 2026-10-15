import 'dart:io';

import 'package:aside/features/post/create_post_screen.dart';
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
  // These journeys contain no media; filesystem cleanup has separate coverage.
  @override
  Future<void> removeMedia(String owner, String id) async {}
  bool failWrites = false;
  @override
  Future<void> write(String owner, List<PostDraft> drafts) async {
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('aside-composer-');
    api = MockApiService();
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

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
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

  testWidgets('close saves immediately and reopening resumes the same draft',
      (tester) async {
    await open(tester);
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

  testWidgets('publishing removes the autosaved draft without recreating it',
      (tester) async {
    when(() => api.createPost(
          caption: any(named: 'caption'),
          media: any(named: 'media'),
          groupIds: any(named: 'groupIds'),
          hideAfter24h: any(named: 'hideAfter24h'),
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
        )).called(1);
  });
}
