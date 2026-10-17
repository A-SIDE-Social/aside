import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aside/core/network/api_client.dart';
import 'package:aside/core/network/api_retry.dart';

void main() {
  for (final status in [400, 401, 403, 404, 409, 422]) {
    test('does not automatically retry a permanent $status', () {
      final request = RequestOptions(path: '/fixture');
      expect(
          retryProfileRead(
              0,
              DioException(
                requestOptions: request,
                response: Response(requestOptions: request, statusCode: status),
                type: DioExceptionType.badResponse,
              )),
          isNull);
      expect(
          retryProfileRead(
              0, ApiException(message: 'Fixture', statusCode: status)),
          isNull);
    });
  }
  for (final status in [408, 429, 500, 503]) {
    test('retries a temporary $status at most three times', () {
      final error = ApiException(message: 'Fixture', statusCode: status);
      expect(retryProfileRead(0, error), const Duration(milliseconds: 200));
      expect(retryProfileRead(2, error), const Duration(milliseconds: 800));
      expect(retryProfileRead(3, error), isNull);
    });
  }
  test('retries network failures but not cancellations or parsing failures',
      () {
    final request = RequestOptions(path: '/fixture');
    expect(
        retryProfileRead(
            0,
            DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
            )),
        isNotNull);
    expect(
        retryProfileRead(
            0,
            DioException(
              requestOptions: request,
              type: DioExceptionType.cancel,
            )),
        isNull);
    expect(retryProfileRead(0, const FormatException()), isNull);
  });
}
