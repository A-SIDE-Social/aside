import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:aside/core/crypto/key_storage.dart';

class _Storage extends Mock implements FlutterSecureStorage {}

void main() {
  test(
      'owner marker persists with encryption keys and is removed only by key reset',
      () async {
    final values = <String, String>{'auth_token': 'session-fixture'};
    final platform = _Storage();
    when(() => platform.read(key: any(named: 'key')))
        .thenAnswer((i) async => values[i.namedArguments[#key]]);
    when(() =>
            platform.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((i) async {
      values[i.namedArguments[#key] as String] =
          i.namedArguments[#value] as String;
    });
    when(() => platform.readAll()).thenAnswer((_) async => Map.of(values));
    when(() => platform.delete(key: any(named: 'key'))).thenAnswer((i) async {
      values.remove(i.namedArguments[#key]);
    });
    final storage = SecureKeyStorage(storage: platform);
    expect(await storage.loadOwner(), isNull);
    await storage.saveOwner('account-fixture');
    expect(await SecureKeyStorage(storage: platform).loadOwner(),
        'account-fixture');
    expect(values.keys.where((key) => key.startsWith('e2ee:')), hasLength(1));
    await storage.wipe();
    expect(await storage.loadOwner(), isNull);
    expect(values, {'auth_token': 'session-fixture'});
  });
}
