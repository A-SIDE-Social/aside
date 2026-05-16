import 'dart:ui' show VoidCallback;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

import '../config/env.dart';
import '../storage/secure_storage.dart';
import 'api_endpoints.dart';

/// Wraps [DioException] with user-friendly messages.
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final dynamic data;

  ApiException({required this.message, this.statusCode, this.data});

  factory ApiException.fromDioException(DioException e) {
    final response = e.response;
    final statusCode = response?.statusCode;

    String message;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        message =
            'Connection timed out. Please check your internet and try again.';
        break;
      case DioExceptionType.connectionError:
        message =
            'Unable to connect to the server. Please check your internet connection.';
        break;
      case DioExceptionType.badResponse:
        final serverMessage = response?.data is Map
            ? (response!.data['error'] as String? ??
                response.data['message'] as String?)
            : null;
        message = serverMessage ?? _defaultMessageForStatus(statusCode);
        break;
      case DioExceptionType.cancel:
        message = 'Request was cancelled.';
        break;
      default:
        message = 'Something went wrong. Please try again.';
    }

    return ApiException(
      message: message,
      statusCode: statusCode,
      data: response?.data,
    );
  }

  static String _defaultMessageForStatus(int? statusCode) {
    switch (statusCode) {
      case 400:
        return 'Invalid request. Please check your input.';
      case 401:
        return 'Session expired. Please sign in again.';
      case 403:
        return 'You do not have permission to perform this action.';
      case 404:
        return 'The requested resource was not found.';
      case 409:
        return 'A conflict occurred. Please try again.';
      case 422:
        return 'Invalid data provided.';
      case 429:
        return 'Too many requests. Please wait a moment and try again.';
      case 500:
      case 502:
      case 503:
        return 'Server error. Please try again later.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Dio-based API client with automatic auth token injection and refresh.
class ApiClient {
  final Dio dio;
  final SecureStorage _secureStorage;
  final VoidCallback? onAuthFailure;

  ApiClient({
    required SecureStorage secureStorage,
    this.onAuthFailure,
    Dio? dio,
  })  : _secureStorage = secureStorage,
        dio = dio ?? Dio() {
    this.dio.options = BaseOptions(
      baseUrl: Env.apiBaseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    );

    this.dio.interceptors.add(_AuthInterceptor(
          dio: this.dio,
          secureStorage: _secureStorage,
          onAuthFailure: _handleAuthFailure,
        ));

    if (kDebugMode) {
      this.dio.interceptors.add(LogInterceptor(
            requestBody: true,
            responseBody: true,
          ));
    }
  }

  void _handleAuthFailure() {
    onAuthFailure?.call();
  }
}

class _AuthInterceptor extends Interceptor {
  final Dio _dio;
  final SecureStorage _secureStorage;
  final VoidCallback _onAuthFailure;

  bool _isRefreshing = false;
  final List<_PendingRequest> _pendingRequests = [];

  _AuthInterceptor({
    required Dio dio,
    required SecureStorage secureStorage,
    required VoidCallback onAuthFailure,
  })  : _dio = dio,
        _secureStorage = secureStorage,
        _onAuthFailure = onAuthFailure;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _secureStorage.getAuthToken();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode != 401) {
      handler.next(err);
      return;
    }

    // If already refreshing, queue this request to retry after refresh.
    if (_isRefreshing) {
      _pendingRequests.add(_PendingRequest(err.requestOptions, handler));
      return;
    }

    _isRefreshing = true;
    try {
      final refreshToken = await _secureStorage.getRefreshToken();
      if (refreshToken == null) {
        _onAuthFailure();
        _failPending(err);
        handler.next(err);
        return;
      }

      // Attempt to refresh the token.
      final response = await Dio(BaseOptions(
        baseUrl: _dio.options.baseUrl,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      )).post(
        ApiEndpoints.refreshToken,
        data: {'refresh_token': refreshToken},
      );

      final newAuthToken =
          (response.data['access_token'] ?? response.data['token']) as String?;
      final newRefreshToken = (response.data['refresh_token'] ??
          response.data['refreshToken']) as String?;

      if (newAuthToken == null) {
        _onAuthFailure();
        _failPending(err);
        handler.next(err);
        return;
      }

      await _secureStorage.setAuthToken(newAuthToken);
      if (newRefreshToken != null) {
        await _secureStorage.setRefreshToken(newRefreshToken);
      }

      // Retry the original request with the new token.
      final options = err.requestOptions;
      options.headers['Authorization'] = 'Bearer $newAuthToken';
      final retryResponse = await _dio.fetch(options);
      handler.resolve(retryResponse);

      // Retry all queued requests.
      _retryPending(newAuthToken);
    } on DioException {
      _onAuthFailure();
      _failPending(err);
      handler.next(err);
    } finally {
      _isRefreshing = false;
    }
  }

  void _retryPending(String newToken) {
    final pending = List.of(_pendingRequests);
    _pendingRequests.clear();
    for (final p in pending) {
      p.options.headers['Authorization'] = 'Bearer $newToken';
      _dio.fetch(p.options).then(
            (response) => p.handler.resolve(response),
            onError: (e) => p.handler.next(e is DioException
                ? e
                : DioException(requestOptions: p.options, error: e)),
          );
    }
  }

  void _failPending(DioException err) {
    final pending = List.of(_pendingRequests);
    _pendingRequests.clear();
    for (final p in pending) {
      p.handler.next(err);
    }
  }
}

class _PendingRequest {
  final RequestOptions options;
  final ErrorInterceptorHandler handler;
  _PendingRequest(this.options, this.handler);
}
