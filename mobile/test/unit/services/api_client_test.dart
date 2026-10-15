import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/core/network/api_client.dart';
import 'package:aside/core/network/api_endpoints.dart';
import 'package:aside/core/network/api_service.dart';
import '../../helpers/mocks.dart';

Future<HttpServer> unauthorizedServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..statusCode = HttpStatus.unauthorized
      ..headers.contentType = ContentType.json
      ..write('{"error":"unauthorized"}');
    await request.response.close();
  });
  return server;
}

void main() {
  group('ApiException', () {
    test('fromDioException maps connectionTimeout', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionTimeout,
      );
      final apiEx = ApiException.fromDioException(e);
      expect(apiEx.message, contains('timed out'));
    });

    test('fromDioException extracts server error from response body', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 400,
          data: {'error': 'Invalid phone number'},
        ),
      );
      final apiEx = ApiException.fromDioException(e);
      expect(apiEx.message, 'Invalid phone number');
      expect(apiEx.statusCode, 400);
    });

    test('fromDioException uses message field when error is absent', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 422,
          data: {'message': 'Validation failed'},
        ),
      );
      final apiEx = ApiException.fromDioException(e);
      expect(apiEx.message, 'Validation failed');
    });

    test('fromDioException falls back to status message when no body', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 404,
          data: 'Not Found',
        ),
      );
      final apiEx = ApiException.fromDioException(e);
      expect(apiEx.message, contains('not found'));
    });

    test('preserves statusCode and data', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 429,
          data: {'error': 'Rate limited'},
        ),
      );
      final apiEx = ApiException.fromDioException(e);
      expect(apiEx.statusCode, 429);
      expect(apiEx.data, isA<Map>());
    });
  });

  group('ApiClient construction', () {
    test('creates with SecureStorage dependency', () {
      final mockStorage = MockSecureStorage();
      final client = ApiClient(secureStorage: mockStorage);
      expect(client.dio, isNotNull);
      expect(client.dio.options.connectTimeout, const Duration(seconds: 30));
      expect([
        'ios',
        'android',
        'web',
        'other',
      ], contains(client.dio.options.headers['X-A-Side-Client-Platform']));
      expect(client.dio.options.headers['X-A-Side-Client-Generation'], '2');
      expect(client.dio.options.headers['X-A-Side-Request-Attempt'], 'initial');
    });

    test('accepts optional Dio instance', () {
      final mockStorage = MockSecureStorage();
      final customDio = Dio();
      final client = ApiClient(secureStorage: mockStorage, dio: customDio);
      expect(client.dio, same(customDio));
    });

    test('calls onAuthFailure callback when provided', () {
      final mockStorage = MockSecureStorage();
      // Just verify the client accepts the callback — actual invocation
      // happens through the interceptor on 401 with no refresh token.
      final client = ApiClient(
        secureStorage: mockStorage,
        onAuthFailure: () {},
      );
      expect(client, isNotNull);
    });
  });

  group('ApiClient auth recovery boundaries', () {
    test('does not treat an OTP verification 401 as session expiry', () async {
      final server = await unauthorizedServer();
      addTearDown(() => server.close(force: true));
      final storage = MockSecureStorage();
      when(() => storage.getAuthToken()).thenAnswer((_) async => null);
      var authFailures = 0;
      final client = ApiClient(
        secureStorage: storage,
        onAuthFailure: () => authFailures += 1,
      );
      client.dio.options.baseUrl =
          'http://${InternetAddress.loopbackIPv4.address}:${server.port}';

      await expectLater(
        client.dio.post(ApiEndpoints.verifyOtp),
        throwsA(isA<DioException>()),
      );

      expect(authFailures, 0);
      verifyNever(() => storage.getRefreshToken());
    });

    test(
      'calls auth failure once for a protected 401 without refresh token',
      () async {
        final server = await unauthorizedServer();
        addTearDown(() => server.close(force: true));
        final storage = MockSecureStorage();
        when(() => storage.getAuthToken()).thenAnswer((_) async => null);
        when(() => storage.getRefreshToken()).thenAnswer((_) async => null);
        var authFailures = 0;
        final client = ApiClient(
          secureStorage: storage,
          onAuthFailure: () => authFailures += 1,
        );
        client.dio.options.baseUrl =
            'http://${InternetAddress.loopbackIPv4.address}:${server.port}';

        await expectLater(
          client.dio.get(ApiEndpoints.me),
          throwsA(isA<DioException>()),
        );

        expect(authFailures, 1);
      },
    );

    test('does not recover authentication for sign-out cleanup 401s', () async {
      final server = await unauthorizedServer();
      addTearDown(() => server.close(force: true));
      final storage = MockSecureStorage();
      when(() => storage.getAuthToken()).thenAnswer((_) async => null);
      var authFailures = 0;
      final client = ApiClient(
        secureStorage: storage,
        onAuthFailure: () => authFailures += 1,
      );
      client.dio.options.baseUrl =
          'http://${InternetAddress.loopbackIPv4.address}:${server.port}';

      await expectLater(
        ApiService(client).revokeDeviceKeys(),
        throwsA(isA<DioException>()),
      );

      expect(authFailures, 0);
      verifyNever(() => storage.getRefreshToken());
    });
  });
}
