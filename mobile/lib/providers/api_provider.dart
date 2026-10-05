import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../core/network/api_service.dart';
import '../core/storage/secure_storage.dart';
import 'auth_provider.dart';

/// Provides the raw Dio-based [ApiClient].
final apiClientProvider = Provider<ApiClient>((ref) {
  final secureStorage = SecureStorage();
  return ApiClient(
    secureStorage: secureStorage,
    onAuthFailure: () {
      // Session recovery failed. Do not call authenticated cleanup routes.
      unawaited(ref.read(authProvider.notifier).handleAuthFailure());
    },
  );
});

/// Provides the high-level [ApiService] built on top of [ApiClient].
final apiServiceProvider = Provider<ApiService>((ref) {
  final client = ref.watch(apiClientProvider);
  return ApiService(client);
});
