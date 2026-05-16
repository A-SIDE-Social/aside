import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';
import 'package:aside/core/storage/secure_storage.dart';

void main() {
  late MockFlutterSecureStorage mockStorage;
  late SecureStorage secureStorage;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();
    secureStorage = SecureStorage(storage: mockStorage);
  });

  group('SecureStorage', () {
    test('getAuthToken reads from correct key', () async {
      when(() => mockStorage.read(key: 'auth_token'))
          .thenAnswer((_) async => 'token123');

      final result = await secureStorage.getAuthToken();
      expect(result, 'token123');
      verify(() => mockStorage.read(key: 'auth_token')).called(1);
    });

    test('setAuthToken writes to correct key', () async {
      when(() => mockStorage.write(key: 'auth_token', value: 'newtoken'))
          .thenAnswer((_) async {});

      await secureStorage.setAuthToken('newtoken');
      verify(() => mockStorage.write(key: 'auth_token', value: 'newtoken'))
          .called(1);
    });

    test('getRefreshToken reads from correct key', () async {
      when(() => mockStorage.read(key: 'refresh_token'))
          .thenAnswer((_) async => 'refresh123');

      final result = await secureStorage.getRefreshToken();
      expect(result, 'refresh123');
    });

    test('setRefreshToken writes to correct key', () async {
      when(() => mockStorage.write(key: 'refresh_token', value: 'newrefresh'))
          .thenAnswer((_) async {});

      await secureStorage.setRefreshToken('newrefresh');
      verify(() => mockStorage.write(key: 'refresh_token', value: 'newrefresh'))
          .called(1);
    });

    test('getUserId reads from correct key', () async {
      when(() => mockStorage.read(key: 'user_id'))
          .thenAnswer((_) async => 'u1');

      final result = await secureStorage.getUserId();
      expect(result, 'u1');
    });

    test('setUserId writes to correct key', () async {
      when(() => mockStorage.write(key: 'user_id', value: 'u2'))
          .thenAnswer((_) async {});

      await secureStorage.setUserId('u2');
      verify(() => mockStorage.write(key: 'user_id', value: 'u2')).called(1);
    });

    test('clearAll deletes all stored values', () async {
      when(() => mockStorage.deleteAll()).thenAnswer((_) async {});

      await secureStorage.clearAll();
      verify(() => mockStorage.deleteAll()).called(1);
    });
  });
}
