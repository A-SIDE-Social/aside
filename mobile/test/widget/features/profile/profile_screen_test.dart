import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/models/user.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:aside/features/profile/profile_screen.dart';
import '../../../helpers/fixtures.dart';
import '../../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;

  setUp(() {
    mockApi = MockApiService();
  });

  Widget createProfileScreen({String? userId}) {
    final user = User.fromJson(userJson(
      id: 'me-1',
      displayName: 'My Name',
      bio: 'My bio text',
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
        home: ProfileScreen(userId: userId),
      ),
    );
  }

  group('ProfileScreen — own profile', () {
    testWidgets('displays own name and bio', (tester) async {
      when(() => mockApi.getUserPosts(any())).thenAnswer((_) async => []);

      await tester.pumpWidget(createProfileScreen());
      await tester.pumpAndSettle();

      // Name appears only in AppBar (removed from body)
      expect(find.text('My Name'), findsOneWidget);
      expect(find.text('My bio text'), findsOneWidget);
    });

    testWidgets('shows empty state when no posts', (tester) async {
      when(() => mockApi.getUserPosts(any())).thenAnswer((_) async => []);

      await tester.pumpWidget(createProfileScreen());
      await tester.pumpAndSettle();

      expect(find.text('No posts yet'), findsOneWidget);
    });
  });

  group('ProfileScreen — other user', () {
    testWidgets('shows Connect button for non-connected user', (tester) async {
      when(() => mockApi.getUser('u2')).thenAnswer(
        (_) async => {
          ...userJson(id: 'u2', displayName: 'Other Person'),
          'is_mutual_follow': false,
          'is_following': false,
          'is_followed_by': false,
          'mutual_follow_count': 0,
        },
      );
      when(() => mockApi.getUserPosts('u2')).thenAnswer((_) async => []);

      await tester.pumpWidget(createProfileScreen(userId: 'u2'));
      await tester.pumpAndSettle();

      // Name in AppBar only
      expect(find.text('Other Person'), findsOneWidget);
      // Connect button visible
      expect(find.text('Connect'), findsOneWidget);
      // Content is private
      expect(find.text('Content is private'), findsOneWidget);
    });

    testWidgets('shows Message button for mutual connection', (tester) async {
      when(() => mockApi.getUser('u3')).thenAnswer(
        (_) async => {
          ...userJson(id: 'u3', displayName: 'Best Friend'),
          'is_mutual_follow': true,
          'is_following': true,
          'is_followed_by': true,
          'mutual_follow_count': 5,
        },
      );
      when(() => mockApi.getUserPosts('u3')).thenAnswer((_) async => []);

      await tester.pumpWidget(createProfileScreen(userId: 'u3'));
      await tester.pumpAndSettle();

      expect(find.text('Best Friend'), findsOneWidget);
      expect(find.text('Message'), findsOneWidget);
    });

    testWidgets('shows Requested button when already following',
        (tester) async {
      when(() => mockApi.getUser('u4')).thenAnswer(
        (_) async => {
          ...userJson(id: 'u4', displayName: 'Pending Person'),
          'is_mutual_follow': false,
          'is_following': true,
          'is_followed_by': false,
          'mutual_follow_count': 0,
        },
      );
      when(() => mockApi.getUserPosts('u4')).thenAnswer((_) async => []);

      await tester.pumpWidget(createProfileScreen(userId: 'u4'));
      await tester.pumpAndSettle();

      expect(find.text('Requested'), findsOneWidget);
    });

    testWidgets('shows Accept button when followed by other user',
        (tester) async {
      when(() => mockApi.getUser('u5')).thenAnswer(
        (_) async => {
          ...userJson(id: 'u5', displayName: 'Requester'),
          'is_mutual_follow': false,
          'is_following': false,
          'is_followed_by': true,
          'mutual_follow_count': 0,
        },
      );
      when(() => mockApi.getUserPosts('u5')).thenAnswer((_) async => []);

      await tester.pumpWidget(createProfileScreen(userId: 'u5'));
      await tester.pumpAndSettle();

      expect(find.text('Accept'), findsOneWidget);
    });
  });
}
