import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:aside/core/network/api_client.dart';
import 'package:aside/core/network/api_endpoints.dart';
import '../../helpers/mocks.dart';

void main() {
  for (final changedLogin in [false, true]) {
    test(
        'session proof retries rotation but not a different login ($changedLogin)',
        () async {
      var credential = 'rt2.fixture-session.first';
      var failures = 0;
      final bodies = <Map<String, dynamic>>[];
      final storage = MockSecureStorage();
      when(() => storage.getUserId()).thenAnswer((_) async => 'fixture-owner');
      when(() => storage.getAuthToken())
          .thenAnswer((_) async => 'fixture-access');
      when(() => storage.getRefreshToken()).thenAnswer((_) async => credential);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>);
        request.response.headers.contentType = ContentType.json;
        if (bodies.length == 1) {
          credential = changedLogin
              ? 'rt2.another-login.next'
              : 'rt2.fixture-session.next';
          request.response
            ..statusCode = 409
            ..write('{"code":"key_session_changed"}');
        } else {
          request.response
            ..statusCode = 200
            ..write('{"ok":true}');
        }
        await request.response.close();
      });
      final client =
          ApiClient(secureStorage: storage, onAuthFailure: () => failures++);
      client.dio.options.baseUrl = 'http://127.0.0.1:${server.port}';
      addTearDown(() async {
        client.dio.close(force: true);
        await server.close(force: true);
      });
      final call = client.postForKeySession(
          ApiEndpoints.deviceKeysUpload, {'owner_user_id': 'fixture-owner'});
      if (changedLogin) {
        await expectLater(call, throwsStateError);
        expect(bodies.length, 1);
      } else {
        expect((await call).statusCode, 200);
        expect(bodies.map((b) => b['refresh_token']),
            ['rt2.fixture-session.first', 'rt2.fixture-session.next']);
      }
      expect(
          bodies.every((b) => b['owner_user_id'] == 'fixture-owner'), isTrue);
      expect(failures, 0);
      verifyNever(() => storage.refreshNonce(any()));
    });
  }

  test('session proof cannot be sent to another host or arbitrary route',
      () async {
    final client = ApiClient(secureStorage: MockSecureStorage());
    addTearDown(() => client.dio.close(force: true));
    for (final path in ['https://example.test/v1/devices/revoke', '/v1/feed']) {
      await expectLater(
          client.postForKeySession(path, {}), throwsArgumentError);
    }
  });

  test('a mismatched account never sends its saved session proof', () async {
    final storage = MockSecureStorage();
    when(() => storage.getUserId()).thenAnswer((_) async => 'new-owner');
    final client = ApiClient(secureStorage: storage);
    addTearDown(() => client.dio.close(force: true));
    await expectLater(
        client.postForKeySession(
            ApiEndpoints.deviceKeysUpload, {'owner_user_id': 'previous-owner'}),
        throwsStateError);
    verifyNever(() => storage.getRefreshToken());
  });
}
