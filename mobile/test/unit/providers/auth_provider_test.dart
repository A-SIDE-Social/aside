import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/models/user.dart';
import 'package:aside/providers/auth_provider.dart';
import '../../helpers/fixtures.dart';
import '../../helpers/mocks.dart';

void main() {
  late MockApiService mockApi;
  late MockSecureStorage mockStorage;
  late ProviderContainer container;
  late AuthNotifier notifier;

  setUp(() {
    mockApi = MockApiService();
    mockStorage = MockSecureStorage();
    container = ProviderContainer(overrides: [
      authProvider.overrideWith(() => AuthNotifier(
            secureStorage: mockStorage,
            apiService: mockApi,
            onDeepLink: (_) {},
            autoInitialize: false,
          )),
    ]);
    addTearDown(container.dispose);
    notifier = container.read(authProvider.notifier);
  });

  group('AuthState', () {
    test('default status is initial', () {
      expect(notifier.state.status, AuthStatus.initial);
      expect(notifier.state.user, isNull);
      expect(notifier.state.error, isNull);
    });

    test('copyWith replaces specified fields', () {
      const state = AuthState(status: AuthStatus.authenticated);
      final updated = state.copyWith(error: 'fail');
      expect(updated.status, AuthStatus.authenticated);
      expect(updated.error, 'fail');
    });
  });

  group('AuthNotifier.initialize', () {
    test('sets unauthenticated when no tokens stored', () async {
      when(() => mockStorage.getAuthToken()).thenAnswer((_) async => null);
      when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);

      await notifier.initialize();
      expect(notifier.state.status, AuthStatus.unauthenticated);
    });

    test('sets authenticated and populates user when tokens valid', () async {
      when(() => mockStorage.getAuthToken())
          .thenAnswer((_) async => 'valid-token');
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'valid-refresh');
      when(() => mockApi.getMe()).thenAnswer((_) async => {
            'user': userJson(id: 'u1', displayName: 'Alice'),
          });

      // _initPush will throw (no Firebase in test) — catch unhandled async error
      await runZonedGuarded(
        () => notifier.initialize(),
        (_, __) {},
      );
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.user?.id, 'u1');
      expect(notifier.state.user?.displayName, 'Alice');
    });

    test('sets unauthenticated and clears storage on 401', () async {
      when(() => mockStorage.getAuthToken())
          .thenAnswer((_) async => 'expired-token');
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'refresh');
      when(() => mockApi.getMe()).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 401,
        ),
      ));
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.initialize();
      expect(notifier.state.status, AuthStatus.unauthenticated);
      verify(() => mockStorage.clearAll()).called(1);
    });

    test('sets unauthenticated and clears storage on 403', () async {
      when(() => mockStorage.getAuthToken()).thenAnswer((_) async => 'token');
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'refresh');
      when(() => mockApi.getMe()).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/'),
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 403,
        ),
      ));
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.initialize();
      expect(notifier.state.status, AuthStatus.unauthenticated);
      verify(() => mockStorage.clearAll()).called(1);
    });

    test('preserves tokens on network error', () async {
      when(() => mockStorage.getAuthToken()).thenAnswer((_) async => 'token');
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'refresh');
      when(() => mockApi.getMe()).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      ));

      await notifier.initialize();
      expect(notifier.state.status, AuthStatus.unauthenticated);
      verifyNever(() => mockStorage.clearAll());
    });
  });

  group('AuthNotifier.signOut', () {
    test('calls apiService.logout with refresh token', () async {
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'refresh-token');
      when(() => mockApi.logout('refresh-token')).thenAnswer((_) async => {});
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.signOut();
      verify(() => mockApi.logout('refresh-token')).called(1);
    });

    test('clears secure storage', () async {
      when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.signOut();
      verify(() => mockStorage.clearAll()).called(1);
    });

    test('sets state to unauthenticated', () async {
      when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.signOut();
      expect(notifier.state.status, AuthStatus.unauthenticated);
    });

    test('succeeds even when server logout fails', () async {
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'refresh');
      when(() => mockApi.logout('refresh'))
          .thenThrow(Exception('Network error'));
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.signOut();
      expect(notifier.state.status, AuthStatus.unauthenticated);
    });
  });

  group('AuthNotifier.refreshSession', () {
    test('refreshes tokens and updates storage', () async {
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'old-refresh');
      when(() => mockApi.refreshToken('old-refresh')).thenAnswer((_) async => {
            'access_token': 'new-access',
            'refresh_token': 'new-refresh',
          });
      when(() => mockStorage.setAuthToken('new-access'))
          .thenAnswer((_) async {});
      when(() => mockStorage.setRefreshToken('new-refresh'))
          .thenAnswer((_) async {});

      await notifier.refreshSession();
      verify(() => mockStorage.setAuthToken('new-access')).called(1);
      verify(() => mockStorage.setRefreshToken('new-refresh')).called(1);
    });

    test('signs out when no refresh token available', () async {
      when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.refreshSession();
      expect(notifier.state.status, AuthStatus.unauthenticated);
    });

    test('signs out when refresh API call fails', () async {
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'refresh');
      when(() => mockApi.refreshToken('refresh')).thenThrow(Exception('fail'));
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.refreshSession();
      expect(notifier.state.status, AuthStatus.unauthenticated);
    });
  });

  group('AuthNotifier.reregisterPushToken', () {
    test('no-ops when push service has not been initialized', () async {
      await notifier.reregisterPushToken();
    });

    test('delegates to the initialized push service', () async {
      final mockPush = MockPushNotificationService();
      when(() => mockPush.reregister()).thenAnswer((_) async {});

      final pushContainer = ProviderContainer(overrides: [
        authProvider.overrideWith(() => AuthNotifier(
              secureStorage: mockStorage,
              apiService: mockApi,
              onDeepLink: (_) {},
              pushService: mockPush,
              autoInitialize: false,
            )),
      ]);
      addTearDown(pushContainer.dispose);

      await pushContainer.read(authProvider.notifier).reregisterPushToken();

      verify(() => mockPush.reregister()).called(1);
    });
  });

  group('AuthNotifier.setUser', () {
    test('updates user in authenticated state', () {
      final user = User.fromJson(userJson(id: 'u1', displayName: 'Alice'));
      notifier.setUser(user);

      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.user?.id, 'u1');
      expect(notifier.state.user?.displayName, 'Alice');
    });
  });
}
