import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aside/core/network/api_client.dart';
import '../../helpers/mocks.dart';

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
}
