import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

/// Profile reads may retry temporary failures, not access denials or missing
/// resources. Manual refresh remains available after the bounded retry budget.
Duration? retryProfileRead(int retryCount, Object error) {
  final int? status;
  if (error is DioException) {
    if (error.type == DioExceptionType.cancel) return null;
    status = error.response?.statusCode;
  } else if (error is ApiException) {
    status = error.statusCode;
  } else {
    return null;
  }
  if (status != null && status != 408 && status != 429 && status < 500) {
    return null;
  }
  return ProviderContainer.defaultRetry(retryCount, error, maxRetries: 3);
}
