import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/features/post/post_detail_screen.dart';
import 'package:aside/core/network/api_client.dart';
import 'package:aside/models/user.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:aside/widgets/comments_sheet.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;

  setUp(() {
    mockApi = MockApiService();
  });

  Widget createScreen({Widget? home}) {
    final user = User.fromJson(userJson(
      id: 'me-1',
      displayName: 'My Name',
    ));

    return ProviderScope(
      overrides: [
        apiServiceProvider.overrideWithValue(mockApi),
        authProvider.overrideWith(() => AuthNotifier(
              secureStorage: MockSecureStorage(),
              apiService: mockApi,
              onDeepLink: (_) {},
              autoInitialize: false,
              initialUser: user,
            )),
      ],
      child: MaterialApp(
        home: home ?? const PostDetailScreen(postId: 'p1'),
      ),
    );
  }

  testWidgets('post detail comments request sentence capitalization',
      (tester) async {
    when(() => mockApi.getPost('p1')).thenAnswer(
      (_) async => postJson(id: 'p1', media: []),
    );
    when(() => mockApi.getComments('p1')).thenAnswer((_) async => []);
    await tester.pumpWidget(createScreen());
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Add a comment...');
    expect(tester.widget<TextField>(field).textCapitalization,
        TextCapitalization.sentences);
  });

  testWidgets('Home comment sheet requests sentence capitalization',
      (tester) async {
    when(() => mockApi.getComments('p1')).thenAnswer((_) async => []);
    await tester.pumpWidget(createScreen(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showCommentsSheet(context, 'p1'),
            child: const Text('Open comments'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open comments'));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Add a comment...');
    expect(tester.widget<TextField>(field).textCapitalization,
        TextCapitalization.sentences);
  });

  Future<void> openComposer(WidgetTester tester, bool sheet,
      {Object? loadError}) async {
    when(() => mockApi.getPost('p1'))
        .thenAnswer((_) async => postJson(id: 'p1', media: []));
    if (loadError == null) {
      when(() => mockApi.getComments('p1')).thenAnswer((_) async => []);
    } else {
      when(() => mockApi.getComments('p1'))
          .thenAnswer((_) async => throw loadError);
    }
    await tester.pumpWidget(createScreen(
      home: sheet
          ? Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => showCommentsSheet(context, 'p1'),
                      child: const Text('Open comments'),
                    ),
                  ))
          : null,
    ));
    await tester.pumpAndSettle();
    if (sheet) {
      await tester.tap(find.text('Open comments'));
      await tester.pumpAndSettle();
    }
  }

  for (final sheet in [false, true]) {
    final surface = sheet ? 'sheet' : 'detail';
    testWidgets(
        '$surface does not submit after comment loading reports an unavailable post',
        (tester) async {
      await openComposer(tester, sheet,
          loadError: ApiException(message: 'Post not found', statusCode: 404));
      await tester.enterText(
          find.widgetWithText(TextField, 'Add a comment...'), 'Keep this');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      verifyNever(() => mockApi.createComment(any(), any(),
          replyToCommentId: any(named: 'replyToCommentId')));
      expect(
          find.text(
              'This post is no longer available. You can copy your draft below.'),
          findsOneWidget);
    });
    testWidgets(
        '$surface keeps a rejected draft and stops resending to an unavailable post',
        (tester) async {
      when(() => mockApi.createComment('p1', 'My unsent draft',
              replyToCommentId: any(named: 'replyToCommentId')))
          .thenThrow(ApiException(message: 'Post not found', statusCode: 404));
      await openComposer(tester, sheet);
      final field = find.widgetWithText(TextField, 'Add a comment...');
      await tester.enterText(field, 'My unsent draft');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(
          tester.widget<TextField>(field).controller!.text, 'My unsent draft');
      expect(
          find.text(
              'This post is no longer available. You can copy your draft below.'),
          findsOneWidget);
      final button = find.ancestor(
          of: find.byIcon(Icons.send_rounded),
          matching: find.byType(IconButton));
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      verify(() => mockApi.createComment('p1', 'My unsent draft',
          replyToCommentId: any(named: 'replyToCommentId'))).called(1);
    });

    for (final status in [403, 503]) {
      testWidgets('$surface preserves the draft and manual retry after $status',
          (tester) async {
        when(() => mockApi.createComment('p1', 'Try later',
                replyToCommentId: any(named: 'replyToCommentId')))
            .thenThrow(ApiException(message: 'Try later', statusCode: status));
        await openComposer(tester, sheet);
        final field = find.widgetWithText(TextField, 'Add a comment...');
        await tester.enterText(field, 'Try later');
        await tester.tap(find.byIcon(Icons.send_rounded));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, 'Try later');
        final button = find.ancestor(
            of: find.byIcon(Icons.send_rounded),
            matching: find.byType(IconButton));
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        verify(() => mockApi.createComment('p1', 'Try later',
            replyToCommentId: any(named: 'replyToCommentId'))).called(1);
      });
    }

    testWidgets(
        '$surface ignores a successful send after the composer is disposed',
        (tester) async {
      final response = Completer<dynamic>();
      when(() => mockApi.createComment('p1', 'Pending',
              replyToCommentId: any(named: 'replyToCommentId')))
          .thenAnswer((_) => response.future);
      await openComposer(tester, sheet);
      await tester.enterText(
          find.widgetWithText(TextField, 'Add a comment...'), 'Pending');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      response.complete({});
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  group('PostDetailScreen reactions', () {
    testWidgets('tapping an existing reaction sends one toggle request',
        (tester) async {
      when(() => mockApi.getPost('p1')).thenAnswer(
        (_) async => postJson(
          id: 'p1',
          userId: 'friend-1',
          caption: 'Lunch',
          media: [],
          reactions: [
            {'emoji': '🔥', 'count': 1, 'reacted_by_me': true},
          ],
        ),
      );
      when(() => mockApi.getComments('p1')).thenAnswer((_) async => []);
      when(() => mockApi.getFeed(
            before: any(named: 'before'),
            groupId: any(named: 'groupId'),
          )).thenAnswer((_) async => {'posts': []});
      when(() => mockApi.togglePostReaction('p1', '🔥'))
          .thenAnswer((_) async => []);

      await tester.pumpWidget(createScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('🔥'));
      await tester.pumpAndSettle();

      verify(() => mockApi.togglePostReaction('p1', '🔥')).called(1);
    });
  });
}
