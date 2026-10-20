import 'dart:ui' show VoidCallback;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kDebugMode, kIsWeb;

import '../config/env.dart';
import '../storage/secure_storage.dart';
import 'api_endpoints.dart';

String get asideClientPlatform {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    _ => 'other',
  };
}

const skipAuthRecoveryExtra = 'skipAuthRecovery';
const _authRetriedExtra = 'authRetried';

const _publicAuthPaths = {
  ApiEndpoints.requestOtp,
  ApiEndpoints.verifyOtp,
  ApiEndpoints.refreshToken,
};

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
        'X-A-Side-Client-Platform': asideClientPlatform,
        'X-A-Side-Client-Generation': '2',
        'X-A-Side-Request-Attempt': 'initial',
      },
    );

    this.dio.interceptors.add(
          _AuthInterceptor(
            dio: this.dio,
            secureStorage: _secureStorage,
            onAuthFailure: _handleAuthFailure,
          ),
        );

    if (kDebugMode) {
      final logger = LogInterceptor(requestBody: true, responseBody: true);
      this.dio.interceptors.add(
            InterceptorsWrapper(
              onRequest: (request, handler) =>
                  request.extra['sensitiveMedia'] == true
                      ? handler.next(request)
                      : logger.onRequest(request, handler),
              onResponse: (response, handler) =>
                  response.requestOptions.extra['sensitiveMedia'] == true
                      ? handler.next(response)
                      : logger.onResponse(response, handler),
              onError: (error, handler) =>
                  error.requestOptions.extra['sensitiveMedia'] == true
                      ? handler.next(error)
                      : logger.onError(error, handler),
            ),
          );
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

  Future<({String accessToken, String refreshToken})>? _refreshInFlight;
  // Keep the session marker private and in memory only. Never attach refresh
  // credentials to request extras or diagnostic metadata.
  final _requestSessions = Expando<_RequestSession>();
  String? _lastObservedToken;
  bool _authFailureNotified = false;

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
    try {
      if (options.extra[skipAuthRecoveryExtra] != true &&
          !_publicAuthPaths.contains(options.uri.path)) {
        final refreshToken = await _secureStorage.getRefreshToken();
        final session = _requestSessions[options];
        if (session != null && session.refreshToken != refreshToken) {
          throw const _SessionChanged();
        }
        _requestSessions[options] = _RequestSession(refreshToken);
      }
      final token = await _secureStorage.getAuthToken();
      if (token != null) {
        if (token != _lastObservedToken) {
          _lastObservedToken = token;
          _authFailureNotified = false;
        }
        options.headers['Authorization'] = 'Bearer $token';
      } else {
        options.headers.remove('Authorization');
      }
      handler.next(options);
    } on _SessionChanged {
      handler.reject(DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
        message: 'Session changed during authentication recovery.',
      ));
    } catch (error, stackTrace) {
      handler.reject(DioException(
        requestOptions: options,
        error: error,
        stackTrace: stackTrace,
      ));
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final request = err.requestOptions;
    final skipsAuthRecovery = request.extra[skipAuthRecoveryExtra] == true ||
        _publicAuthPaths.contains(request.uri.path);
    if (err.response?.statusCode != 401 || skipsAuthRecovery) {
      handler.next(err);
      return;
    }

    try {
      final refreshToken = await _secureStorage.getRefreshToken();
      final session = _requestSessions[request];
      if (session != null && session.refreshToken != refreshToken) {
        throw const _SessionChanged();
      }
      final currentToken = await _secureStorage.getAuthToken();
      if (request.extra[_authRetriedExtra] == true) {
        // A retried request must never wait for its own refresh operation.
        // Also avoid signing out a newer session for a delayed old response.
        if (request.headers['Authorization'] != 'Bearer $currentToken') {
          throw const _SessionChanged();
        }
        _notifyAuthFailure();
        handler.next(err);
        return;
      }
      if (_authFailureNotified) {
        handler.next(err);
        return;
      }

      // A slow response may have used the old token even though another
      // request already finished refreshing it. Reuse the current token.
      final credentials = currentToken != null &&
              request.headers['Authorization'] != 'Bearer $currentToken'
          ? (accessToken: currentToken, refreshToken: refreshToken)
          : await _refreshAuthToken();
      _requestSessions[request] = _RequestSession(credentials.refreshToken);
      request.extra[_authRetriedExtra] = true;
      request.headers['Authorization'] = 'Bearer ${credentials.accessToken}';
      request.headers['X-A-Side-Request-Attempt'] = 'auth_retry';
      final retryResponse = await _dio.fetch(request);
      handler.resolve(retryResponse);
    } on _SessionExpired {
      _notifyAuthFailure();
      handler.next(err);
    } on _SessionChanged {
      handler.next(DioException(
        requestOptions: request,
        type: DioExceptionType.cancel,
        message: 'Session changed during authentication recovery.',
      ));
    } on DioException catch (error) {
      // Preserve the actual failure, not the original 401: startup must not
      // mistake a refresh outage or a retried resource's 404 for session expiry.
      handler.next(error.copyWith(requestOptions: request));
    } catch (error, stackTrace) {
      handler.next(DioException(
        requestOptions: request,
        error: error,
        stackTrace: stackTrace,
      ));
    }
  }

  void _notifyAuthFailure() {
    if (_authFailureNotified) return;
    _authFailureNotified = true;
    _onAuthFailure();
  }

  Future<({String accessToken, String refreshToken})> _refreshAuthToken() {
    final pending = _refreshInFlight;
    if (pending != null) return pending;
    late final Future<({String accessToken, String refreshToken})> refresh;
    refresh = _performRefresh().whenComplete(() {
      if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
    });
    _refreshInFlight = refresh;
    return refresh;
  }

  Future<({String accessToken, String refreshToken})> _performRefresh() async {
    final refreshToken = await _secureStorage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const _SessionExpired();
    }
    Duration boundedTimeout(Duration? configured) {
      const limit = Duration(seconds: 30);
      return configured == null ||
              configured <= Duration.zero ||
              configured > limit
          ? limit
          : configured;
    }

    final refreshDio = Dio(BaseOptions(
      baseUrl: _dio.options.baseUrl,
      connectTimeout: boundedTimeout(_dio.options.connectTimeout),
      sendTimeout: boundedTimeout(_dio.options.sendTimeout),
      receiveTimeout: boundedTimeout(_dio.options.receiveTimeout),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-A-Side-Client-Platform': asideClientPlatform,
        'X-A-Side-Client-Generation': '2',
        'X-A-Side-Request-Attempt': 'initial',
      },
    ));
    try {
      final response = await refreshDio.post(
        ApiEndpoints.refreshToken,
        data: {'refresh_token': refreshToken},
      );
      if (await _secureStorage.getRefreshToken() != refreshToken) {
        throw const _SessionChanged();
      }
      final data = response.data;
      if (data is! Map) throw const FormatException('Invalid session response');
      final token = data['access_token'] ?? data['token'];
      final nextRefreshToken = data['refresh_token'] ?? data['refreshToken'];
      if (token is! String ||
          token.isEmpty ||
          (nextRefreshToken != null &&
              (nextRefreshToken is! String || nextRefreshToken.isEmpty))) {
        throw const FormatException('Invalid session response');
      }
      await _secureStorage.setAuthToken(token);
      if (nextRefreshToken != null) {
        await _secureStorage.setRefreshToken(nextRefreshToken as String);
      }
      return (
        accessToken: token,
        refreshToken: nextRefreshToken as String? ?? refreshToken
      );
    } on DioException catch (error) {
      if (await _secureStorage.getRefreshToken() != refreshToken) {
        throw const _SessionChanged();
      }
      if (error.response?.statusCode == 401) {
        throw const _SessionExpired();
      }
      rethrow;
    } finally {
      refreshDio.close(force: true);
    }
  }
}

class _SessionExpired implements Exception {
  const _SessionExpired();
}

class _SessionChanged implements Exception {
  const _SessionChanged();
}

class _RequestSession {
  final String? refreshToken;
  const _RequestSession(this.refreshToken);
}
