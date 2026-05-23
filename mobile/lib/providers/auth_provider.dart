import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/env.dart';
import '../core/crypto/key_registry_sync.dart';
import '../core/network/api_client.dart';
import '../core/network/api_service.dart';
import '../core/platform/app_group_channel.dart';
import '../core/platform/deep_link.dart';
import '../core/platform/push_notification_service.dart';
import '../core/services/revenuecat_service.dart';
import '../core/services/socket_service.dart';
import '../core/storage/secure_storage.dart';
import '../models/user.dart';
import 'crypto_provider.dart';
import 'socket_provider.dart';

enum AuthStatus { initial, loading, unauthenticated, authenticated }

class AuthState {
  final AuthStatus status;
  final User? user;
  final String? error;

  const AuthState({
    this.status = AuthStatus.initial,
    this.user,
    this.error,
  });

  AuthState copyWith({
    AuthStatus? status,
    User? user,
    String? error,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      error: error,
    );
  }
}

/// Riverpod 3 Notifier — `build()` resolves deps (either from ref-driven
/// providers or test-injected overrides), kicks off `initialize()`, and
/// returns the synchronous initial state.
///
/// Why deps live on the notifier as nullable injection slots: tests
/// construct `AuthNotifier(secureStorage: …, apiService: …, …)` and
/// override the provider via `authProvider.overrideWith(() => …)` so
/// the subclass-style deps land before `build()` runs. Production
/// reads everything from sibling providers (signalClientProvider,
/// socketServiceProvider) and constructs the inline ApiClient/ApiService
/// pair to break the apiClient↔auth Riverpod cycle (see comment near
/// the bottom of the file).
class AuthNotifier extends Notifier<AuthState> {
  AuthNotifier({
    SecureStorage? secureStorage,
    ApiService? apiService,
    void Function(String route)? onDeepLink,
    KeyRegistrySync? keyRegistrySync,
    SocketService? socketService,
    PushNotificationService? pushService,
    bool autoInitialize = true,
    User? initialUser,
  })  : _injectedSecureStorage = secureStorage,
        _injectedApiService = apiService,
        _injectedOnDeepLink = onDeepLink,
        _injectedKeyRegistrySync = keyRegistrySync,
        _injectedSocketService = socketService,
        _injectedPushService = pushService,
        _autoInitialize = autoInitialize,
        _initialUser = initialUser;

  // Test-injection slots — null in production.
  final SecureStorage? _injectedSecureStorage;
  final ApiService? _injectedApiService;
  final void Function(String route)? _injectedOnDeepLink;
  final KeyRegistrySync? _injectedKeyRegistrySync;
  final SocketService? _injectedSocketService;
  final PushNotificationService? _injectedPushService;
  final bool _autoInitialize;
  final User? _initialUser;

  // Resolved deps — set during build(). late-final because build() runs
  // exactly once per provider lifetime.
  late final SecureStorage _secureStorage;
  late final ApiService _apiService;
  late final void Function(String route) _onDeepLink;
  KeyRegistrySync? _keyRegistrySync;
  SocketService? _socketService;
  PushNotificationService? _pushService;

  @override
  AuthState build() {
    _secureStorage = _injectedSecureStorage ?? SecureStorage();

    final injectedApi = _injectedApiService;
    if (injectedApi != null) {
      _apiService = injectedApi;
    } else {
      // Construct a dedicated ApiClient/ApiService pair inline rather
      // than reading `apiServiceProvider`. That provider's
      // `apiClientProvider` parent installs an `onAuthFailure` callback
      // that closes back into `authProvider.notifier.signOut()` — a
      // top-level Riverpod cycle if we tried to read it from this
      // notifier's `build()`. The inline pair has its own auth-failure
      // hook that calls our own `signOut()` method directly.
      final apiClient = ApiClient(
        secureStorage: _secureStorage,
        onAuthFailure: () {
          // Called by the interceptor on unrecoverable 401. Drop into
          // our own signOut() so storage + state stay consistent.
          // Fire-and-forget — interceptor doesn't await.
          // ignore: discarded_futures
          signOut();
        },
      );
      _apiService = ApiService(apiClient);
    }

    _keyRegistrySync = _injectedKeyRegistrySync ??
        KeyRegistrySync(ref.read(signalClientProvider), _apiService);
    _socketService = _injectedSocketService ?? ref.read(socketServiceProvider);
    _pushService = _injectedPushService;

    _onDeepLink = _injectedOnDeepLink ??
        (route) {
          ref.read(pendingDeepLinkProvider.notifier).set(route);
        };

    if (_autoInitialize) {
      // Schedule on a microtask so the first `state =` assignment
      // inside initialize() runs AFTER build() returns its initial
      // value. Riverpod 3 throws "Tried to read the state of an
      // uninitialized provider" if we mutate state before build()
      // completes its first return.
      // ignore: discarded_futures
      Future.microtask(initialize);
    }

    if (_initialUser != null) {
      return AuthState(
        status: AuthStatus.authenticated,
        user: _initialUser,
      );
    }
    return const AuthState();
  }

  /// Connects the realtime socket with the current auth token so
  /// incoming DMs can push to the conversation screen live. Safe to
  /// call on every transition into authenticated — the service
  /// disconnects any existing connection before reconnecting.
  Future<void> _connectSocket() async {
    final service = _socketService;
    if (service == null) return;
    final token = await _secureStorage.getAuthToken();
    if (token == null) return;
    service.connect(token);
  }

  /// Fire-and-forget E2EE key bootstrap. Safe to call on every
  /// transition into [AuthStatus.authenticated] — a no-op if keys
  /// are already provisioned locally. Failures are logged but don't
  /// block sign-in: E2EE isn't required for core app functionality
  /// until DM encryption ships (Phase 1e), and a subsequent sign-in
  /// attempt will retry.
  void _bootstrapE2eeKeys() {
    final sync = _keyRegistrySync;
    if (sync == null) return;
    // Intentionally unawaited.
    // ignore: discarded_futures
    sync.ensureKeysInitialized().then(
      (_) {},
      onError: (Object e, StackTrace _) {
        debugPrint('E2EE key bootstrap failed: $e');
      },
    );
  }

  void _initPush() {
    _pushService ??= PushNotificationService(
      _apiService,
      onDeepLink: _onDeepLink,
    );
    _pushService!.initialize();
  }

  /// Re-assert the FCM token with the backend. The backend upsert is
  /// idempotent, so this is safe to call on every app resume and repairs a
  /// missing server-side device-token row without waiting for token rotation.
  Future<void> reregisterPushToken() async {
    await _pushService?.reregister();
  }

  /// Check for existing tokens and attempt to load the user profile.
  Future<void> initialize() async {
    state = state.copyWith(status: AuthStatus.loading);

    try {
      final token = await _secureStorage.getAuthToken();
      final refreshToken = await _secureStorage.getRefreshToken();

      if (token == null && refreshToken == null) {
        state = state.copyWith(status: AuthStatus.unauthenticated);
        return;
      }

      // Try to fetch the user profile. If the access token is expired,
      // the interceptor will automatically refresh it and retry.
      final data = await _apiService.getMe() as Map<String, dynamic>;
      final user = User.fromJson(data['user'] as Map<String, dynamic>);

      // Sync token to App Group for extensions — re-read in case interceptor refreshed it
      final currentToken = await _secureStorage.getAuthToken();
      if (currentToken != null) {
        await AppGroupChannel.setToken(currentToken);
        await AppGroupChannel.setApiBaseUrl(Env.apiBaseUrl);
        await AppGroupChannel.reloadWidgets();
      }

      state = AuthState(status: AuthStatus.authenticated, user: user);

      // Identify user with RevenueCat.
      RevenueCatService.identify(user.id);

      // Initialize push notifications after auth
      _initPush();

      // Kick off E2EE key provisioning if this is the first run with
      // E2EE enabled (or if the client generated keys but failed to
      // upload last time). No-op if already provisioned.
      _bootstrapE2eeKeys();

      // Connect the realtime socket so new DMs push live.
      unawaited(_connectSocket());
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        // Auth is truly invalid — clear everything.
        await _secureStorage.clearAll();
      }
      // For network/server errors, keep tokens so next launch can retry.
      state = state.copyWith(status: AuthStatus.unauthenticated);
    } catch (_) {
      // Keep tokens on unexpected errors.
      state = state.copyWith(status: AuthStatus.unauthenticated);
    }
  }

  /// Request an OTP code to be sent to the user's email.
  Future<void> requestOtp(String email) async {
    await _apiService.requestOtp(email);
  }

  /// Verify the OTP code and authenticate or register.
  /// For new users, pass [inviteCode] and [displayName].
  Future<void> verifyOtp(
    String email,
    String code, {
    String? inviteCode,
    String? displayName,
  }) async {
    try {
      final data = await _apiService.verifyOtp(
        email,
        code,
        inviteCode: inviteCode,
        displayName: displayName,
      );

      final responseMap = data as Map<String, dynamic>;
      final token =
          (responseMap['access_token'] ?? responseMap['token']) as String;
      final refreshToken = (responseMap['refresh_token'] ??
          responseMap['refreshToken']) as String;
      final userData = responseMap['user'] as Map<String, dynamic>;

      await _secureStorage.setAuthToken(token);
      await _secureStorage.setRefreshToken(refreshToken);

      // Sync to App Group for Share Extension and Widget
      await AppGroupChannel.setToken(token);
      await AppGroupChannel.setApiBaseUrl(Env.apiBaseUrl);

      final user = User.fromJson(userData);
      await _secureStorage.setUserId(user.id);
      await AppGroupChannel.setUserId(user.id);
      await AppGroupChannel.reloadWidgets();

      state = AuthState(status: AuthStatus.authenticated, user: user);

      // Identify user with RevenueCat.
      RevenueCatService.identify(user.id);

      // Initialize push notifications after auth
      _initPush();

      // Fresh sign-in: generate and upload the user's E2EE key
      // bundle so peers can initiate sessions with them. Fire-and-
      // forget; user can use the app even if this fails.
      _bootstrapE2eeKeys();

      // Connect the realtime socket so incoming DMs push live.
      unawaited(_connectSocket());
    } catch (e) {
      // Don't change auth state — the sign-in screen handles the error.
      // Changing to unauthenticated triggers a router rebuild that resets
      // the screen's local state (losing the OTP step / registration step).
      rethrow;
    }
  }

  /// Refresh the current auth session using the stored refresh token.
  Future<void> refreshSession() async {
    try {
      final refreshToken = await _secureStorage.getRefreshToken();
      if (refreshToken == null) {
        await signOut();
        return;
      }

      final data = await _apiService.refreshToken(refreshToken);
      final responseMap = data as Map<String, dynamic>;
      final newToken =
          (responseMap['access_token'] ?? responseMap['token']) as String;
      final newRefreshToken = (responseMap['refresh_token'] ??
          responseMap['refreshToken']) as String?;

      await _secureStorage.setAuthToken(newToken);
      if (newRefreshToken != null) {
        await _secureStorage.setRefreshToken(newRefreshToken);
      }
      // Keep App Group token in sync
      await AppGroupChannel.setToken(newToken);
    } catch (_) {
      await signOut();
    }
  }

  /// Sign out: clear tokens and set state to unauthenticated.
  Future<void> signOut() async {
    try {
      final refreshToken = await _secureStorage.getRefreshToken();
      if (refreshToken != null) {
        await _apiService.logout(refreshToken);
      }
    } catch (_) {
      // Best-effort server logout; continue clearing local state.
    }
    // Revoke E2EE keys on server and wipe locally. Best-effort —
    // losing Keychain access or a network blip shouldn't block
    // sign-out; the server has per-user-revoke idempotent semantics
    // so a retry later is safe.
    try {
      await _keyRegistrySync?.resetKeys();
    } catch (_) {}
    _socketService?.disconnect();
    await _pushService?.unregister();
    await RevenueCatService.logOut();
    await _secureStorage.clearAll();
    await AppGroupChannel.clearToken();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Disable push notifications by unregistering the device token.
  Future<void> disablePush() async {
    await _pushService?.unregister();
  }

  /// Re-enable push notifications by re-initializing the push service.
  Future<void> enablePush() async {
    _initPush();
  }

  /// Update the local user after a profile edit without re-fetching.
  void setUser(User user) {
    state = AuthState(status: AuthStatus.authenticated, user: user);
  }
}

final authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
