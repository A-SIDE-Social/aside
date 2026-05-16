import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/models/user.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:aside/features/profile/connections_screen.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;

  setUp(() {
    mockApi = MockApiService();
  });

  Widget createConnectionsScreen() {
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
      child: const MaterialApp(home: ConnectionsScreen()),
    );
  }

  testWidgets('shows connections and requests sections', (tester) async {
    when(() => mockApi.getMutualFollows()).thenAnswer(
      (_) async => [
        userJson(id: 'u2', displayName: 'Alice'),
        userJson(id: 'u3', displayName: 'Bob'),
      ],
    );
    when(() => mockApi.getInboundFollows()).thenAnswer(
      (_) async => [
        userJson(id: 'u4', displayName: 'Charlie'),
      ],
    );

    await tester.pumpWidget(createConnectionsScreen());
    await tester.pumpAndSettle();

    // Requests section header
    expect(find.text('Requests'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);

    // Connected section
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('shows Accept button and dismiss icon for requests',
      (tester) async {
    when(() => mockApi.getMutualFollows()).thenAnswer((_) async => []);
    when(() => mockApi.getInboundFollows()).thenAnswer(
      (_) async => [
        userJson(id: 'u4', displayName: 'Charlie'),
      ],
    );

    await tester.pumpWidget(createConnectionsScreen());
    await tester.pumpAndSettle();

    expect(find.text('Accept'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('hides Requests section when no inbound follows', (tester) async {
    when(() => mockApi.getMutualFollows()).thenAnswer(
      (_) async => [
        userJson(id: 'u2', displayName: 'Alice'),
      ],
    );
    when(() => mockApi.getInboundFollows()).thenAnswer((_) async => []);

    await tester.pumpWidget(createConnectionsScreen());
    await tester.pumpAndSettle();

    expect(find.text('Requests'), findsNothing);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('shows empty state when no connections and no requests',
      (tester) async {
    when(() => mockApi.getMutualFollows()).thenAnswer((_) async => []);
    when(() => mockApi.getInboundFollows()).thenAnswer((_) async => []);

    await tester.pumpWidget(createConnectionsScreen());
    await tester.pumpAndSettle();

    // Build 40: empty-state copy renamed from "No connections yet"
    // when the screen was relabeled "Friends" on the Settings side.
    expect(find.text('No friends yet'), findsOneWidget);
  });
}
