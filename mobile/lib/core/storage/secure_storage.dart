import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

class SecureStorage {
  static const _authTokenKey = 'auth_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _userIdKey = 'user_id';
  static const _refreshAttemptKey = 'refresh_attempt';
  static Future<void> _attemptWrites = Future.value();

  /// Persist a random retry secret before sending a refresh. A lost response
  /// can then recover the same rotation after an app restart. Never log it.
  Future<String> refreshNonce(String credential) async {
    late String nonce;
    final operation = _attemptWrites.then((_) async {
      final fingerprint = sha256.convert(utf8.encode(credential)).toString();
      final raw = await _storage.read(key: _refreshAttemptKey);
      final saved = raw == null ? null : jsonDecode(raw);
      if (saved is Map &&
          saved['token_hash'] == fingerprint &&
          saved['nonce'] is String) {
        nonce = saved['nonce'] as String;
      } else {
        final random = Random.secure();
        nonce = base64Url
            .encode(List.generate(32, (_) => random.nextInt(256)))
            .replaceAll('=', '');
        await _storage.write(
            key: _refreshAttemptKey,
            value: jsonEncode({'token_hash': fingerprint, 'nonce': nonce}));
      }
    });
    _attemptWrites = operation.catchError((Object _) {});
    await operation;
    return nonce;
  }

  final FlutterSecureStorage _storage;

  SecureStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // flutter_secure_storage 10 deprecated
              // `encryptedSharedPreferences` (Google deprecated the
              // underlying Jetpack Security library). Cipher
              // selection is no longer configurable from here;
              // existing data migrates automatically on first access.
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  // Auth token

  Future<String?> getAuthToken() async {
    return _storage.read(key: _authTokenKey);
  }

  Future<void> setAuthToken(String token) async {
    await _storage.write(key: _authTokenKey, value: token);
  }

  // Refresh token

  Future<String?> getRefreshToken() async {
    return _storage.read(key: _refreshTokenKey);
  }

  Future<void> setRefreshToken(String token) async {
    await _storage.write(key: _refreshTokenKey, value: token);
  }

  // User ID

  Future<String?> getUserId() async {
    return _storage.read(key: _userIdKey);
  }

  Future<void> setUserId(String userId) async {
    await _storage.write(key: _userIdKey, value: userId);
  }

  // Clear all session values owned by this class. Do not use deleteAll():
  // E2EE key material shares the platform secure-storage backend under its
  // own prefix and must only be removed by SecureKeyStorage.wipe().

  Future<void> clearAll() async {
    await Future.wait([
      _storage.delete(key: _authTokenKey),
      _storage.delete(key: _refreshTokenKey),
      _storage.delete(key: _userIdKey),
      _storage.delete(key: _refreshAttemptKey),
    ]);
  }
}
