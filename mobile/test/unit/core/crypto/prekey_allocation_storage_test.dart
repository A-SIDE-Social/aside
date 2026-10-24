import 'dart:typed_data';

import 'package:aside/core/crypto/key_storage.dart';
import 'package:aside/src/rust/api/prekeys.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Platform extends Mock implements FlutterSecureStorage {}

void main() {
  late Map<String, String> values;
  late _Platform platform;
  late SecureKeyStorage storage;
  var failCounterWrite = false;

  setUp(() {
    values = {'auth_token': 'session-fixture'};
    platform = _Platform();
    failCounterWrite = false;
    when(() => platform.read(key: any(named: 'key')))
        .thenAnswer((i) async => values[i.namedArguments[#key]]);
    when(() => platform.readAll()).thenAnswer((_) async => Map.of(values));
    when(() =>
            platform.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((i) async {
      final key = i.namedArguments[#key] as String;
      if (failCounterWrite && key.endsWith('_last_id')) {
        throw StateError('Storage unavailable');
      }
      values[key] = i.namedArguments[#value] as String;
    });
    when(() => platform.delete(key: any(named: 'key'))).thenAnswer((i) async {
      values.remove(i.namedArguments[#key]);
    });
    storage = SecureKeyStorage(storage: platform);
  });

  OneTimePreKey otpk(int id) =>
      OneTimePreKey(id: id, serialized: Uint8List(1), publicKey: Uint8List(33));
  KyberPreKey kyber(int id) => KyberPreKey(
      id: id,
      serialized: Uint8List(1),
      publicKey: Uint8List(1568),
      signature: Uint8List(64));

  test('allocation counters survive depletion and reopening, but not key reset',
      () async {
    await Future.wait([
      storage.saveOneTimePreKey(otpk(8)),
      storage.saveOneTimePreKey(otpk(3)),
      storage.saveKyberPreKey(kyber(9)),
      storage.saveKyberPreKey(kyber(2))
    ]);
    await storage.deleteOneTimePreKey(8);
    await storage.deleteOneTimePreKey(3);
    await storage.deleteKyberPreKey(9);
    await storage.deleteKyberPreKey(2);
    final reopened = SecureKeyStorage(storage: platform);
    expect(await reopened.listOneTimePreKeyIds(), isEmpty);
    expect(await reopened.listKyberPreKeyIds(), isEmpty);
    expect(await reopened.lastOneTimePreKeyId(), 8);
    expect(await reopened.lastKyberPreKeyId(), 9);
    await reopened.wipe();
    expect(await reopened.lastOneTimePreKeyId(), 0);
    expect(await reopened.lastKyberPreKeyId(), 0);
    expect(values, {'auth_token': 'session-fixture'});
  });

  test('consumption migrates legacy records before deleting their IDs',
      () async {
    values['e2ee:otpk:80'] = 'legacy-fixture';
    values['e2ee:kpk:40'] = 'legacy-fixture';
    await storage.deleteOneTimePreKey(80);
    await storage.deleteKyberPreKey(40);
    expect(await storage.lastOneTimePreKeyId(), 80);
    expect(await storage.lastKyberPreKeyId(), 40);
  });

  test('counter failures preserve consumed records and later writes recover',
      () async {
    values['e2ee:otpk:80'] = 'legacy-fixture';
    failCounterWrite = true;
    await expectLater(storage.deleteOneTimePreKey(80), throwsStateError);
    expect(values['e2ee:otpk:80'], 'legacy-fixture');
    await expectLater(storage.saveKyberPreKey(kyber(40)), throwsStateError);
    expect(values.containsKey('e2ee:kpk:40'), isFalse);
    failCounterWrite = false;
    await storage.deleteOneTimePreKey(80);
    await storage.saveKyberPreKey(kyber(40));
    expect(await storage.lastOneTimePreKeyId(), 80);
    expect(await storage.lastKyberPreKeyId(), 40);
  });

  test('parallel allocations reserve distinct ranges across storage wrappers',
      () async {
    final other = SecureKeyStorage(storage: platform);
    final ranges = await Future.wait([
      storage.reserveOneTimePreKeyIds(3),
      other.reserveOneTimePreKeyIds(2),
      storage.reserveOneTimePreKeyIds(1, minimumLastId: 20),
    ]);
    expect(ranges, [1, 4, 21]);
    expect(await storage.lastOneTimePreKeyId(), 21);
    // A crash before saving a batch must not free its reserved IDs.
    expect(await other.reserveOneTimePreKeyIds(2), 22);
  });

  test('allocation migrates legacy records and refuses exhausted ranges',
      () async {
    values['e2ee:otpk:80'] = 'legacy-fixture';
    expect(await storage.reserveOneTimePreKeyIds(2), 81);
    expect(await storage.reserveKyberPreKeyIds(2, minimumLastId: 500), 501);
    await expectLater(
        storage.reserveKyberPreKeyIds(2, minimumLastId: 2147483646),
        throwsStateError);
    expect(await storage.lastKyberPreKeyId(), 502);
  });

  test('recovery markers persist but never delete private records or sessions',
      () async {
    values['e2ee:otpk:1'] = 'private-record';
    values['e2ee:session:fixture'] = 'saved-session';
    await storage.savePrekeyRecovery(const PrekeyRecoveryState(100, 50));
    final reopened = SecureKeyStorage(storage: platform);
    expect((await reopened.loadPrekeyRecovery())!.pending, isTrue);
    await reopened
        .savePrekeyRecovery(const PrekeyRecoveryState(100, 50, pending: false));
    expect((await storage.loadPrekeyRecovery())!.oneTimeFloor, 100);
    expect((await storage.loadPrekeyRecovery())!.pending, isFalse);
    expect(values['e2ee:otpk:1'], 'private-record');
    expect(values['e2ee:session:fixture'], 'saved-session');
  });
}
