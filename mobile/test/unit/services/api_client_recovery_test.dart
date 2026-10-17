import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/core/network/api_client.dart';
import 'package:aside/core/network/api_endpoints.dart';
import '../../helpers/mocks.dart';

class _RecoveryFixture {
  final storage = MockSecureStorage();
  late final HttpServer server;
  late final ApiClient client;
  String? accessToken = 'expired-fixture';
  String? refreshToken = 'refresh-fixture';
  int refreshStatus = 200;
  Object refreshBody = {'access_token': 'renewed-fixture'};
  int retryStatus = 200;
  int refreshCalls = 0;
  int expiredCalls = 0;
  int authFailures = 0;
  bool holdRefresh = false;
  bool failStorageRead = false;
  final refreshArrived = Completer<void>();
  final attempts = <String, List<String?>>{};
  Future<void> Function(HttpRequest)? beforeReply;

  Future<void> start() async {
    when(() => storage.getAuthToken()).thenAnswer((_) async {
      if (failStorageRead) throw StateError('Storage unavailable');
      return accessToken;
    });
    when(() => storage.getRefreshToken()).thenAnswer((_) async => refreshToken);
    when(() => storage.setAuthToken(any())).thenAnswer((invocation) async {
      accessToken = invocation.positionalArguments[0] as String;
    });
    when(() => storage.setRefreshToken(any())).thenAnswer((invocation) async {
      refreshToken = invocation.positionalArguments[0] as String;
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final isRefresh = request.uri.path == ApiEndpoints.refreshToken;
      final expired =
          request.headers.value('Authorization') == 'Bearer expired-fixture';
      if (isRefresh) {
        refreshCalls++;
        if (!refreshArrived.isCompleted) refreshArrived.complete();
      } else {
        if (expired) expiredCalls++;
        attempts.putIfAbsent(request.uri.path, () => []).add(
              request.headers.value('X-A-Side-Request-Attempt'),
            );
      }
      await request.drain<void>();
      await beforeReply?.call(request);
      if (isRefresh && holdRefresh) return;
      request.response
        ..headers.contentType = ContentType.json
        ..statusCode = isRefresh
            ? refreshStatus
            : expired
                ? 401
                : retryStatus
        ..write(jsonEncode(isRefresh ? refreshBody : {'ok': true}));
      await request.response.close();
    });
    client = ApiClient(
      secureStorage: storage,
      onAuthFailure: () => authFailures++,
    );
    client.dio.interceptors.removeWhere((value) => value is LogInterceptor);
    client.dio.options.baseUrl = 'http://127.0.0.1:${server.port}';
    addTearDown(() async {
      client.dio.close(force: true);
      await server.close(force: true);
    });
  }

  Future<DioException> failure(String path) async {
    try {
      await client.dio.get(path).timeout(const Duration(seconds: 3));
      fail('Expected the request to fail');
    } on DioException catch (error) {
      return error;
    }
  }
}

void main() {
  late _RecoveryFixture fixture;
  setUp(() async {
    fixture = _RecoveryFixture();
    await fixture.start();
  });

  test('concurrent expired requests share one refresh and retry once',
      () async {
    final allExpired = Completer<void>();
    fixture.beforeReply = (request) async {
      if (fixture.expiredCalls == 3 && !allExpired.isCompleted) {
        allExpired.complete();
      }
      if (request.uri.path == ApiEndpoints.refreshToken) {
        await allExpired.future;
      }
    };
    final responses = await Future.wait([
      fixture.client.dio.get(ApiEndpoints.me),
      fixture.client.dio.get('/v1/feed'),
      fixture.client.dio.get('/v1/lists'),
    ]).timeout(const Duration(seconds: 3));
    expect(responses.map((value) => value.statusCode), everyElement(200));
    expect(fixture.refreshCalls, 1);
    expect(fixture.authFailures, 0);
    expect(fixture.accessToken, 'renewed-fixture');
    for (final attempts in fixture.attempts.values) {
      expect(attempts, ['initial', 'auth_retry']);
    }
  });

  test('a delayed old-token 401 reuses the already refreshed token', () async {
    final slowArrived = Completer<void>();
    final releaseSlow = Completer<void>();
    fixture.beforeReply = (request) async {
      if (request.uri.path == '/v1/slow' &&
          request.headers.value('X-A-Side-Request-Attempt') == 'initial') {
        slowArrived.complete();
        await releaseSlow.future;
      }
    };
    final slow = fixture.client.dio.get('/v1/slow');
    await slowArrived.future;
    await fixture.client.dio.get(ApiEndpoints.me);
    releaseSlow.complete();
    expect((await slow).statusCode, 200);
    expect(fixture.refreshCalls, 1);
    expect(fixture.attempts['/v1/slow'], ['initial', 'auth_retry']);
  });

  for (final status in [404, 503]) {
    test('a retried resource $status does not sign out or become a 401',
        () async {
      fixture.retryStatus = status;
      final error = await fixture.failure(ApiEndpoints.me);
      expect(error.response?.statusCode, status);
      expect(error.requestOptions.path, ApiEndpoints.me);
      expect(fixture.authFailures, 0);
      expect(fixture.refreshCalls, 1);
      expect(fixture.accessToken, 'renewed-fixture');
    });
  }

  for (final status in [429, 503]) {
    test('refresh $status preserves credentials and returns the real failure',
        () async {
      fixture.refreshStatus = status;
      final error = await fixture.failure(ApiEndpoints.me);
      expect(error.response?.statusCode, status);
      expect(error.requestOptions.path, ApiEndpoints.me);
      expect(fixture.authFailures, 0);
      expect(fixture.accessToken, 'expired-fixture');
      expect(fixture.refreshToken, 'refresh-fixture');
      fixture.refreshStatus = 200;
      expect((await fixture.client.dio.get(ApiEndpoints.me)).statusCode, 200);
      expect(fixture.refreshCalls, 2);
    });
  }

  test('a refresh timeout preserves credentials and settles the request',
      () async {
    fixture.holdRefresh = true;
    fixture.client.dio.options.receiveTimeout =
        const Duration(milliseconds: 100);
    final error = await fixture.failure(ApiEndpoints.me);
    expect(error.type, DioExceptionType.receiveTimeout);
    expect(fixture.authFailures, 0);
    expect(fixture.accessToken, 'expired-fixture');
    expect(fixture.refreshToken, 'refresh-fixture');
  });

  test('a second 401 settles all callers without another refresh or deadlock',
      () async {
    fixture.retryStatus = 401;
    final errors = await Future.wait([
      fixture.failure(ApiEndpoints.me),
      fixture.failure('/v1/feed'),
      fixture.failure('/v1/lists'),
    ]);
    expect(
        errors.map((error) => error.response?.statusCode), everyElement(401));
    expect(fixture.refreshCalls, 1);
    expect(fixture.authFailures, 1);
    expect(fixture.attempts.values, everyElement(['initial', 'auth_retry']));
  });

  test('a rejected refresh notifies once and settles concurrent callers',
      () async {
    fixture.refreshStatus = 401;
    await Future.wait([
      fixture.failure(ApiEndpoints.me),
      fixture.failure('/v1/feed'),
    ]);
    expect(fixture.authFailures, 1);
    expect(fixture.refreshCalls, 1);
  });

  test('missing refresh credentials notify once without a refresh request',
      () async {
    fixture.refreshToken = null;
    await Future.wait([
      fixture.failure(ApiEndpoints.me),
      fixture.failure('/v1/feed'),
    ]);
    expect(fixture.authFailures, 1);
    expect(fixture.refreshCalls, 0);
  });

  for (final response in [
    <String, dynamic>{},
    {'access_token': 42},
    'invalid'
  ]) {
    test('malformed refresh response preserves the local session: $response',
        () async {
      fixture.refreshBody = response;
      final error = await fixture.failure(ApiEndpoints.me);
      expect(error.response, isNull);
      expect(fixture.authFailures, 0);
      expect(fixture.accessToken, 'expired-fixture');
    });
  }

  test('sign-out during refresh cannot restore the previous session', () async {
    final release = Completer<void>();
    fixture.beforeReply = (request) async {
      if (request.uri.path == ApiEndpoints.refreshToken) await release.future;
    };
    final pending = fixture.failure(ApiEndpoints.me);
    await fixture.refreshArrived.future;
    fixture.accessToken = null;
    fixture.refreshToken = null;
    release.complete();
    expect((await pending).type, DioExceptionType.cancel);
    expect(fixture.accessToken, isNull);
    expect(fixture.authFailures, 0);
    verifyNever(() => fixture.storage.setAuthToken(any()));
  });

  test('a storage failure settles the request instead of leaving it pending',
      () async {
    fixture.failStorageRead = true;
    expect((await fixture.failure(ApiEndpoints.me)).error, isA<StateError>());
    expect(fixture.authFailures, 0);
    expect(fixture.refreshCalls, 0);
  });

  test(
      'a refresh storage failure settles callers and releases the refresh slot',
      () async {
    when(() => fixture.storage.getRefreshToken())
        .thenThrow(StateError('Storage unavailable'));
    expect((await fixture.failure(ApiEndpoints.me)).error, isA<StateError>());
    expect(fixture.authFailures, 0);
    when(() => fixture.storage.getRefreshToken())
        .thenAnswer((_) async => fixture.refreshToken);
    expect((await fixture.client.dio.get(ApiEndpoints.me)).statusCode, 200);
  });

  test('a failed token write is retryable and does not sign out', () async {
    when(() => fixture.storage.setAuthToken(any()))
        .thenThrow(StateError('Storage unavailable'));
    expect((await fixture.failure(ApiEndpoints.me)).error, isA<StateError>());
    expect(fixture.authFailures, 0);
    expect(fixture.accessToken, 'expired-fixture');
  });

  test('a rejected old refresh cannot sign out a newly established session',
      () async {
    final release = Completer<void>();
    fixture.refreshStatus = 401;
    fixture.beforeReply = (request) async {
      if (request.uri.path == ApiEndpoints.refreshToken) await release.future;
    };
    final pending = fixture.failure(ApiEndpoints.me);
    await fixture.refreshArrived.future;
    fixture.accessToken = 'new-session-fixture';
    fixture.refreshToken = 'new-session-refresh';
    release.complete();
    expect((await pending).type, DioExceptionType.cancel);
    expect(fixture.authFailures, 0);
    expect(fixture.accessToken, 'new-session-fixture');
  });

  test('a new sign-in can recover after the previous session was rejected',
      () async {
    fixture.refreshStatus = 401;
    await fixture.failure(ApiEndpoints.me);
    expect(fixture.authFailures, 1);
    fixture.accessToken = 'new-session-fixture';
    fixture.refreshToken = 'new-session-refresh';
    expect((await fixture.client.dio.get(ApiEndpoints.me)).statusCode, 200);
    expect(fixture.authFailures, 1);
  });

  test('a delayed old-session request cannot replay under a new account',
      () async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    fixture.beforeReply = (request) async {
      arrived.complete();
      await release.future;
    };
    final pending = fixture.failure(ApiEndpoints.me);
    await arrived.future;
    fixture.accessToken = 'new-session-fixture';
    fixture.refreshToken = 'new-session-refresh';
    release.complete();
    expect((await pending).type, DioExceptionType.cancel);
    expect(fixture.refreshCalls, 0);
    expect(fixture.authFailures, 0);
    expect(fixture.attempts[ApiEndpoints.me], ['initial']);
  });

  test('refresh-token rotation still allows the original request to retry',
      () async {
    fixture.refreshBody = {
      'access_token': 'renewed-fixture',
      'refresh_token': 'rotated-fixture',
    };
    expect((await fixture.client.dio.get(ApiEndpoints.me)).statusCode, 200);
    expect(fixture.refreshToken, 'rotated-fixture');
    expect(fixture.authFailures, 0);
  });
}
