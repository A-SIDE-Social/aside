import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aside/core/network/api_client.dart';

void main() {
  group('ApiException', () {
    DioException makeDioError({
      DioExceptionType type = DioExceptionType.unknown,
      int? statusCode,
      Map<String, dynamic>? responseData,
    }) {
      return DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: type,
        response: statusCode != null
            ? Response(
                requestOptions: RequestOptions(path: '/test'),
                statusCode: statusCode,
                data: responseData,
              )
            : null,
      );
    }

    test('maps connectionTimeout to friendly message', () {
      final e = ApiException.fromDioException(
        makeDioError(type: DioExceptionType.connectionTimeout),
      );
      expect(e.message, contains('timed out'));
    });

    test('maps sendTimeout to friendly message', () {
      final e = ApiException.fromDioException(
        makeDioError(type: DioExceptionType.sendTimeout),
      );
      expect(e.message, contains('timed out'));
    });

    test('maps receiveTimeout to friendly message', () {
      final e = ApiException.fromDioException(
        makeDioError(type: DioExceptionType.receiveTimeout),
      );
      expect(e.message, contains('timed out'));
    });

    test('maps connectionError to friendly message', () {
      final e = ApiException.fromDioException(
        makeDioError(type: DioExceptionType.connectionError),
      );
      expect(e.message, contains('Unable to connect'));
    });

    test('extracts server error message from response body', () {
      final e = ApiException.fromDioException(
        makeDioError(
          type: DioExceptionType.badResponse,
          statusCode: 400,
          responseData: {'error': 'Phone number is required'},
        ),
      );
      expect(e.message, 'Phone number is required');
      expect(e.statusCode, 400);
    });

    test('extracts message field when error field is absent', () {
      final e = ApiException.fromDioException(
        makeDioError(
          type: DioExceptionType.badResponse,
          statusCode: 422,
          responseData: {'message': 'Invalid data'},
        ),
      );
      expect(e.message, 'Invalid data');
    });

    test('falls back to status-based message when no server message', () {
      final e = ApiException.fromDioException(
        makeDioError(
          type: DioExceptionType.badResponse,
          statusCode: 404,
          responseData: {},
        ),
      );
      expect(e.message, contains('not found'));
    });

    test('handles 401 status', () {
      final e = ApiException.fromDioException(
        makeDioError(
          type: DioExceptionType.badResponse,
          statusCode: 401,
          responseData: {},
        ),
      );
      expect(e.message, contains('Session expired'));
    });

    test('handles 429 status', () {
      final e = ApiException.fromDioException(
        makeDioError(
          type: DioExceptionType.badResponse,
          statusCode: 429,
          responseData: {},
        ),
      );
      expect(e.message, contains('Too many requests'));
    });

    test('handles 500 status', () {
      final e = ApiException.fromDioException(
        makeDioError(
          type: DioExceptionType.badResponse,
          statusCode: 500,
          responseData: {},
        ),
      );
      expect(e.message, contains('Server error'));
    });

    test('handles cancel type', () {
      final e = ApiException.fromDioException(
        makeDioError(type: DioExceptionType.cancel),
      );
      expect(e.message, contains('cancelled'));
    });

    test('handles unknown type', () {
      final e = ApiException.fromDioException(
        makeDioError(type: DioExceptionType.unknown),
      );
      expect(e.message, contains('Something went wrong'));
    });

    test('toString includes status code and message', () {
      final e = ApiException(message: 'test error', statusCode: 404);
      expect(e.toString(), 'ApiException(404): test error');
    });
  });
}
