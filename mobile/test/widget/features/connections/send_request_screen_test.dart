import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/features/connections/send_request_screen.dart';
import 'package:aside/providers/api_provider.dart';
import '../../../helpers/mocks.dart';

void main() {
  const slug = 'k7m2pq9xj4n6';
  late MockApiService mockApi;

  setUp(() {
    mockApi = MockApiService();
  });

  Widget createApp() {
    final router = GoRouter(
      initialLocation: '/invite',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('Home')),
        ),
        GoRoute(
          path: '/invite',
          builder: (_, __) => const SendRequestScreen(slug: slug),
        ),
      ],
    );

    return ProviderScope(
      overrides: [apiServiceProvider.overrideWithValue(mockApi)],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('loads the invite owner and sends a connection request',
      (tester) async {
    when(() => mockApi.getUserBySlug(slug)).thenAnswer(
      (_) async => {
        'id': 'u2',
        'display_name': 'Charlie',
        'avatar_url': null,
      },
    );
    when(() => mockApi.requestFromSlug(slug)).thenAnswer(
      (_) async => {'status': 'requested'},
    );

    await tester.pumpWidget(createApp());
    await tester.pumpAndSettle();

    expect(find.text('Charlie'), findsOneWidget);
    await tester.tap(find.text('Send Request'));
    await tester.pumpAndSettle();

    verify(() => mockApi.requestFromSlug(slug)).called(1);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('guards send from repeated taps while the request is pending',
      (tester) async {
    final completion = Completer<Map<String, dynamic>>();
    when(() => mockApi.getUserBySlug(slug)).thenAnswer(
      (_) async => {'id': 'u2', 'display_name': 'Charlie'},
    );
    when(() => mockApi.requestFromSlug(slug))
        .thenAnswer((_) => completion.future);

    await tester.pumpWidget(createApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send Request'));
    await tester.tap(find.text('Send Request'));
    await tester.pump();

    verify(() => mockApi.requestFromSlug(slug)).called(1);
    completion.complete({'status': 'requested'});
    await tester.pumpAndSettle();
  });

  testWidgets('keeps the action available after a send failure',
      (tester) async {
    when(() => mockApi.getUserBySlug(slug)).thenAnswer(
      (_) async => {'id': 'u2', 'display_name': 'Charlie'},
    );
    when(() => mockApi.requestFromSlug(slug)).thenThrow(Exception('offline'));

    await tester.pumpWidget(createApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send Request'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to send request:'), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Send Request'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('renders a clear stale-link state for a missing invite owner',
      (tester) async {
    when(() => mockApi.getUserBySlug(slug)).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/v1/users/by-slug/$slug'),
        response: Response(
          requestOptions: RequestOptions(path: '/v1/users/by-slug/$slug'),
          statusCode: 404,
        ),
      ),
    );

    await tester.pumpWidget(createApp());
    await tester.pumpAndSettle();

    expect(find.text('This invite link is no longer valid.'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    verifyNever(() => mockApi.requestFromSlug(any()));
  });
}
