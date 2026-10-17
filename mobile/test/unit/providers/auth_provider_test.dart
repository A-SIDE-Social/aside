import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/models/user.dart';
import 'package:aside/core/crypto/key_registry_sync.dart';
import 'package:aside/core/services/socket_service.dart';
import 'package:aside/providers/auth_provider.dart';
import '../../helpers/fixtures.dart';
import '../../helpers/mocks.dart';

class MockKeyRegistrySync extends Mock implements KeyRegistrySync {}

class MockSocketService extends Mock implements SocketService {}

void main() {
  late MockApiService mockApi;
  late MockSecureStorage mockStorage;
  late ProviderContainer container;
  late AuthNotifier notifier;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockApiService();
    mockStorage = MockSecureStorage();
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          () => AuthNotifier(
            secureStorage: mockStorage,
            apiService: mockApi,
            onDeepLink: (_) {},
            autoInitialize: false,
          ),
        ),
      ],
    );
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
      when(
        () => mockStorage.getAuthToken(),
      ).thenAnswer((_) async => 'valid-token');
      when(
        () => mockStorage.getRefreshToken(),
      ).thenAnswer((_) async => 'valid-refresh');
      when(() => mockApi.getMe()).thenAnswer(
        (_) async => {'user': userJson(id: 'u1', displayName: 'Alice')},
      );

      // _initPush will throw (no Firebase in test) — catch unhandled async error
      await runZonedGuarded(() => notifier.initialize(), (_, __) {});
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.user?.id, 'u1');
      expect(notifier.state.user?.displayName, 'Alice');
    });

    test('sets unauthenticated and clears storage on 401', () async {
      when(
        () => mockStorage.getAuthToken(),
      ).thenAnswer((_) async => 'expired-token');
      when(
        () => mockStorage.getRefreshToken(),
      ).thenAnswer((_) async => 'refresh');
      when(() => mockApi.getMe()).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          response: Response(
            requestOptions: RequestOptions(path: '/'),
            statusCode: 401,
          ),
        ),
      );
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.initialize();
      expect(notifier.state.status, AuthStatus.unauthenticated);
      verify(() => mockStorage.clearAll()).called(1);
    });

    test('does not erase credentials for a forbidden profile response',
        () async {
      when(() => mockStorage.getAuthToken()).thenAnswer((_) async => 'token');
      when(
        () => mockStorage.getRefreshToken(),
      ).thenAnswer((_) async => 'refresh');
      when(() => mockApi.getMe()).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          response: Response(
            requestOptions: RequestOptions(path: '/'),
            statusCode: 403,
          ),
        ),
      );
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.initialize();
      expect(notifier.state.status, AuthStatus.recoveryRequired);
      verifyNever(() => mockStorage.clearAll());
    });

    test('preserves tokens on network error', () async {
      when(() => mockStorage.getAuthToken()).thenAnswer((_) async => 'token');
      when(
        () => mockStorage.getRefreshToken(),
      ).thenAnswer((_) async => 'refresh');
      when(() => mockApi.getMe()).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.connectionError,
        ),
      );

      await notifier.initialize();
      expect(notifier.state.status, AuthStatus.recoveryRequired);
      verifyNever(() => mockStorage.clearAll());
    });
  });

  group('startup recovery', () {
    test('retries the saved session after a temporary outage without an OTP',
        () async {
      when(() => mockStorage.getAuthToken()).thenAnswer((_) async => 'token');
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'refresh');
      when(() => mockApi.getMe()).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/me'),
          type: DioExceptionType.connectionError,
        ),
      );

      await notifier.initialize();
      expect(notifier.state.status, AuthStatus.recoveryRequired);
      verifyNever(() => mockStorage.clearAll());

      when(() => mockApi.getMe()).thenAnswer(
        (_) async => {'user': userJson(id: 'u1', displayName: 'Alice')},
      );
      await runZonedGuarded(() => notifier.initialize(), (_, __) {});
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.user?.id, 'u1');
      verify(() => mockApi.getMe()).called(2);
      verifyNever(() => mockStorage.clearAll());
      verifyNever(() => mockApi.requestOtp(any()));
    });

    test('a temporary secure-storage failure offers recovery', () async {
      when(() => mockStorage.getAuthToken())
          .thenThrow(StateError('Storage unavailable'));

      await notifier.initialize();
      expect(notifier.state.status, AuthStatus.recoveryRequired);
      verifyNever(() => mockApi.getMe());
      verifyNever(() => mockStorage.clearAll());
    });
  });

  group('AuthNotifier.signOut', () {
    test('calls apiService.logout with refresh token', () async {
      when(
        () => mockStorage.getRefreshToken(),
      ).thenAnswer((_) async => 'refresh-token');
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
      when(
        () => mockStorage.getRefreshToken(),
      ).thenAnswer((_) async => 'refresh');
      when(
        () => mockApi.logout('refresh'),
      ).thenThrow(Exception('Network error'));
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});

      await notifier.signOut();
      expect(notifier.state.status, AuthStatus.unauthenticated);
    });

    test('auth failure clears locally without protected cleanup', () async {
      final keySync = MockKeyRegistrySync();
      final push = MockPushNotificationService();
      final socket = MockSocketService();
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});
      when(() => socket.disconnect()).thenReturn(null);

      final authFailureContainer = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => AuthNotifier(
              secureStorage: mockStorage,
              apiService: mockApi,
              onDeepLink: (_) {},
              keyRegistrySync: keySync,
              socketService: socket,
              pushService: push,
              autoInitialize: false,
            ),
          ),
        ],
      );
      addTearDown(authFailureContainer.dispose);

      await authFailureContainer
          .read(authProvider.notifier)
          .handleAuthFailure();

      verify(() => mockStorage.clearAll()).called(1);
      verify(() => socket.disconnect()).called(1);
      verifyNever(() => mockStorage.getRefreshToken());
      verifyNever(() => mockApi.logout(any()));
      verifyNever(() => keySync.resetKeys());
      verifyNever(() => push.unregister());
    });

    test('coalesces concurrent auth-failure cleanup', () async {
      final clearStarted = Completer<void>();
      final releaseClear = Completer<void>();
      when(() => mockStorage.clearAll()).thenAnswer((_) async {
        clearStarted.complete();
        await releaseClear.future;
      });

      final first = notifier.handleAuthFailure();
      await clearStarted.future;
      final second = notifier.handleAuthFailure();
      releaseClear.complete();
      await Future.wait([first, second]);

      verify(() => mockStorage.clearAll()).called(1);
    });
  });

  group('AuthNotifier.refreshSession', () {
    test('refreshes tokens and updates storage', () async {
      when(
        () => mockStorage.getRefreshToken(),
      ).thenAnswer((_) async => 'old-refresh');
      when(() => mockApi.refreshToken('old-refresh')).thenAnswer(
        (_) async => {
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
        },
      );
      when(
        () => mockStorage.setAuthToken('new-access'),
      ).thenAnswer((_) async {});
      when(
        () => mockStorage.setRefreshToken('new-refresh'),
      ).thenAnswer((_) async {});

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

    test('preserves the session when refresh fails unexpectedly', () async {
      when(
        () => mockStorage.getRefreshToken(),
      ).thenAnswer((_) async => 'refresh');
      when(() => mockApi.refreshToken('refresh')).thenThrow(Exception('fail'));
      notifier.setUser(User.fromJson(userJson()));
      await expectLater(notifier.refreshSession(), throwsA(isA<Exception>()));
      expect(notifier.state.status, AuthStatus.authenticated);
      verifyNever(() => mockStorage.clearAll());
    });

    for (final status in [429, 503]) {
      test('preserves the session on refresh $status', () async {
        when(() => mockStorage.getRefreshToken())
            .thenAnswer((_) async => 'refresh');
        final request = RequestOptions(path: '/fixture');
        when(() => mockApi.refreshToken('refresh')).thenThrow(DioException(
          requestOptions: request,
          response: Response(requestOptions: request, statusCode: status),
        ));
        notifier.setUser(User.fromJson(userJson()));
        await expectLater(
            notifier.refreshSession(), throwsA(isA<DioException>()));
        expect(notifier.state.status, AuthStatus.authenticated);
        verifyNever(() => mockStorage.clearAll());
      });
    }

    test('clears the session when refresh credentials are rejected', () async {
      when(() => mockStorage.getRefreshToken())
          .thenAnswer((_) async => 'refresh');
      final request = RequestOptions(path: '/fixture');
      when(() => mockApi.refreshToken('refresh')).thenThrow(DioException(
        requestOptions: request,
        response: Response(requestOptions: request, statusCode: 401),
      ));
      when(() => mockStorage.clearAll()).thenAnswer((_) async {});
      await notifier.refreshSession();
      expect(notifier.state.status, AuthStatus.unauthenticated);
      verify(() => mockStorage.clearAll()).called(1);
    });

    test('does not restore a session after sign-out during explicit refresh',
        () async {
      String? token = 'refresh';
      when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => token);
      final response = Completer<Map<String, dynamic>>();
      when(() => mockApi.refreshToken('refresh'))
          .thenAnswer((_) => response.future);
      final pending = notifier.refreshSession();
      await Future<void>.delayed(Duration.zero);
      token = null;
      response.complete({'access_token': 'stale-result'});
      await pending;
      verifyNever(() => mockStorage.setAuthToken(any()));
      verifyNever(() => mockStorage.clearAll());
    });
  });

  group('AuthNotifier.reregisterPushToken', () {
    test('no-ops when push service has not been initialized', () async {
      await notifier.reregisterPushToken();
    });

    test('delegates to the initialized push service', () async {
      final mockPush = MockPushNotificationService();
      when(() => mockPush.reregister()).thenAnswer((_) async {});

      final pushContainer = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => AuthNotifier(
              secureStorage: mockStorage,
              apiService: mockApi,
              onDeepLink: (_) {},
              pushService: mockPush,
              autoInitialize: false,
            ),
          ),
        ],
      );
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
