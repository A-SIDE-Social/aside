import 'dart:convert';
import 'package:aside/core/storage/secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Platform extends Mock implements FlutterSecureStorage {}

void main() {
  test(
      'refresh retry secret survives reopening, changes with credentials and clears on logout',
      () async {
    final values = <String, String>{'e2ee:identity': 'encryption-fixture'};
    final platform = _Platform();
    when(() => platform.read(key: any(named: 'key')))
        .thenAnswer((i) async => values[i.namedArguments[#key]]);
    when(() =>
            platform.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((i) async {
      values[i.namedArguments[#key] as String] =
          i.namedArguments[#value] as String;
    });
    when(() => platform.delete(key: any(named: 'key'))).thenAnswer((i) async {
      values.remove(i.namedArguments[#key]);
    });
    final storage = SecureStorage(storage: platform);
    final first = await storage.refreshNonce('old-credential-fixture');
    expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    final reopened = SecureStorage(storage: platform);
    final concurrent = await Future.wait(List.generate(
        3, (_) => reopened.refreshNonce('old-credential-fixture')));
    expect(concurrent, everyElement(first));
    expect(
        values['refresh_attempt'], isNot(contains('old-credential-fixture')));
    expect(jsonDecode(values['refresh_attempt']!)['nonce'], first);
    expect(
        await reopened.refreshNonce('next-credential-fixture'), isNot(first));
    await reopened.clearAll();
    expect(values, {'e2ee:identity': 'encryption-fixture'});
  });
}
