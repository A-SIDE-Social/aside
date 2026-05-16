import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  static const _authTokenKey = 'auth_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _userIdKey = 'user_id';

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

  // Clear all

  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
