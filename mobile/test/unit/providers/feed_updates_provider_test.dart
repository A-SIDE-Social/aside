import 'dart:async';

import 'package:aside/models/user.dart';
import 'package:aside/providers/api_provider.dart';
import 'package:aside/providers/auth_provider.dart';
import 'package:aside/providers/feed_provider.dart';
import 'package:aside/providers/feed_updates_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/mocks.dart';

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        status: AuthStatus.authenticated,
        user: User.fromJson(userJson(id: 'alice')),
      );

  void signInAs(String id) => state = AuthState(
        status: AuthStatus.authenticated,
        user: User.fromJson(userJson(id: id)),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late MockApiService api;
  late _Auth auth;

  setUp(() {
    api = MockApiService();
    auth = _Auth();
    container = ProviderContainer(overrides: [
      authProvider.overrideWith(() => auth),
      apiServiceProvider.overrideWithValue(api),
    ]);
  });
  tearDown(() => container.dispose());

  test('socket/push duplicates stay dismissed after refresh', () {
    final updates = container.read(feedUpdatesProvider.notifier);
    updates.receive('post-1');
    updates.receive('post-1');
    expect(container.read(feedUpdatesProvider), {'post-1'});
    updates.acknowledge({'post-1'});
    updates.receive('post-1');
    expect(container.read(feedUpdatesProvider), isEmpty);
    auth.signInAs('bob');
    expect(container.read(feedUpdatesProvider), isEmpty);
    container.read(feedUpdatesProvider.notifier).receive('post-1');
    expect(container.read(feedUpdatesProvider), {'post-1'});
  });

  test('posts arriving during a refresh keep their indicator', () async {
    final response = Completer<Map<String, dynamic>>();
    when(() => api.getFeed(
          before: any(named: 'before'),
          groupId: any(named: 'groupId'),
        )).thenAnswer((_) => response.future);
    final updates = container.read(feedUpdatesProvider.notifier);
    updates.receive('before');
    container.read(feedNotifierProvider);
    await Future<void>.delayed(Duration.zero);
    updates.receive('during');
    response.complete({'posts': <dynamic>[]});
    await Future<void>.delayed(Duration.zero);
    expect(container.read(feedUpdatesProvider), {'during'});
  });

  test('failed refresh leaves new posts available to retry', () async {
    when(() => api.getFeed(
          before: any(named: 'before'),
          groupId: any(named: 'groupId'),
        )).thenThrow(Exception('Offline'));
    container.read(feedUpdatesProvider.notifier).receive('post-1');
    container.read(feedNotifierProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(feedUpdatesProvider), {'post-1'});
    expect(container.read(feedNotifierProvider).hasError, true);
  });

  test('refreshing a list only acknowledges posts actually loaded', () async {
    when(() => api.getFeed(
          before: any(named: 'before'),
          groupId: any(named: 'groupId'),
        )).thenAnswer((_) async => {
          'posts': [postJson(id: 'in-list', media: [])],
        });
    container.read(feedGroupFilterProvider.notifier).set('family');
    final updates = container.read(feedUpdatesProvider.notifier);
    updates.receive('in-list');
    updates.receive('outside-list');
    container.read(feedNotifierProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(feedUpdatesProvider), {'outside-list'});
  });
}
