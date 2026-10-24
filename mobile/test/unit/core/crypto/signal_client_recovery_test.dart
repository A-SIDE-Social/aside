import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:aside/core/crypto/key_storage.dart';
import 'package:aside/core/crypto/signal_client.dart';
import 'package:aside/src/rust/api/identity.dart';
import 'package:aside/src/rust/api/prekeys.dart';
import 'package:aside/src/rust/frb_generated.dart';

class _Store extends Mock implements KeyStorage {}

void main() {
  final library = Platform.environment['ASIDE_CRYPTO_TEST_LIBRARY'];
  group('native provisioning recovery', () {
    late _Store storage;
    IdentityKeypair? identity;
    SignedPreKey? signed;
    late Map<int, OneTimePreKey> otpks;
    late Map<int, KyberPreKey> kyber;
    PrekeyRecoveryState? recovery;
    var lastOtpk = 0;
    var lastKyber = 0;
    var failSignedWrite = false;
    var failSecondKyberWrite = false;
    setUpAll(() async {
      registerFallbackValue(const PrekeyRecoveryState(0, 0));
      registerFallbackValue(
          IdentityKeypair(serialized: Uint8List(0), publicKey: Uint8List(0)));
      registerFallbackValue(SignedPreKey(
          id: 1,
          serialized: Uint8List(0),
          publicKey: Uint8List(0),
          signature: Uint8List(0)));
      registerFallbackValue(OneTimePreKey(
          id: 1, serialized: Uint8List(0), publicKey: Uint8List(0)));
      registerFallbackValue(KyberPreKey(
          id: 1,
          serialized: Uint8List(0),
          publicKey: Uint8List(0),
          signature: Uint8List(0)));
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
    });
    setUp(() {
      storage = _Store();
      recovery = null;
      identity = null;
      signed = null;
      otpks = {};
      kyber = {};
      lastOtpk = 0;
      lastKyber = 0;
      failSignedWrite = false;
      failSecondKyberWrite = false;
      when(() => storage.loadPrekeyRecovery())
          .thenAnswer((_) async => recovery);
      when(() => storage.savePrekeyRecovery(any())).thenAnswer((i) async {
        recovery = i.positionalArguments.single as PrekeyRecoveryState;
      });
      when(() => storage.reserveOneTimePreKeyIds(any(),
          minimumLastId: any(named: 'minimumLastId'))).thenAnswer((i) async {
        final floor = i.namedArguments[#minimumLastId] as int;
        if (floor > lastOtpk) lastOtpk = floor;
        final first = lastOtpk + 1;
        lastOtpk += i.positionalArguments.single as int;
        return first;
      });
      when(() => storage.reserveKyberPreKeyIds(any(),
          minimumLastId: any(named: 'minimumLastId'))).thenAnswer((i) async {
        final floor = i.namedArguments[#minimumLastId] as int;
        if (floor > lastKyber) lastKyber = floor;
        final first = lastKyber + 1;
        lastKyber += i.positionalArguments.single as int;
        return first;
      });
      when(() => storage.loadIdentityKeyPair())
          .thenAnswer((_) async => identity);
      when(() => storage.loadSignedPreKey()).thenAnswer((_) async => signed);
      when(() => storage.listOneTimePreKeyIds())
          .thenAnswer((_) async => otpks.keys.toList());
      when(() => storage.listKyberPreKeyIds())
          .thenAnswer((_) async => kyber.keys.toList());
      when(() => storage.lastOneTimePreKeyId())
          .thenAnswer((_) async => lastOtpk);
      when(() => storage.lastKyberPreKeyId())
          .thenAnswer((_) async => lastKyber);
      when(() => storage.deleteOneTimePreKey(any())).thenAnswer((i) async {
        otpks.remove(i.positionalArguments.single);
      });
      when(() => storage.deleteKyberPreKey(any())).thenAnswer((i) async {
        kyber.remove(i.positionalArguments.single);
      });
      when(() => storage.loadOneTimePreKey(any()))
          .thenAnswer((i) async => otpks[i.positionalArguments.single]);
      when(() => storage.loadKyberPreKey(any()))
          .thenAnswer((i) async => kyber[i.positionalArguments.single]);
      when(() => storage.saveIdentityKeyPair(any())).thenAnswer((i) async {
        identity = i.positionalArguments.single as IdentityKeypair;
      });
      when(() => storage.saveSignedPreKey(any())).thenAnswer((i) async {
        if (failSignedWrite) {
          failSignedWrite = false;
          throw StateError('Simulated interrupted write');
        }
        signed = i.positionalArguments.single as SignedPreKey;
      });
      when(() => storage.saveOneTimePreKey(any())).thenAnswer((i) async {
        final key = i.positionalArguments.single as OneTimePreKey;
        if (key.id > lastOtpk) lastOtpk = key.id;
        otpks[key.id] = key;
      });
      when(() => storage.saveKyberPreKey(any())).thenAnswer((i) async {
        if (failSecondKyberWrite && kyber.length == 1) {
          failSecondKyberWrite = false;
          throw StateError('Simulated interrupted write');
        }
        final key = i.positionalArguments.single as KyberPreKey;
        if (key.id > lastKyber) lastKyber = key.id;
        kyber[key.id] = key;
      });
    });

    test('depleted pools never reuse consumed IDs after client restart',
        () async {
      final client = SignalClient(storage);
      await client.resumeInitialKeys(otpkCount: 3, kyberCount: 3);
      final originalIdentity = identity!.serialized.toList();
      // Consume the newest keys first: max(remaining IDs) must not determine
      // the next allocation, even when an older private record remains.
      await client.consumeOneTimePreKey(3);
      await client.consumeOneTimePreKey(2);
      await client.consumeKyberPreKey(3);
      await client.consumeKyberPreKey(2);
      var restarted = SignalClient(storage);
      final nextOtpks =
          await restarted.replenishOneTimePreKeys(threshold: 2, batchSize: 2);
      final nextKyber =
          await restarted.replenishKyberPreKeys(threshold: 2, batchSize: 2);
      expect(nextOtpks.map((key) => key.id), [4, 5]);
      expect(nextKyber.map((key) => key.id), [4, 5]);
      for (final id in otpks.keys.toList()) {
        await restarted.consumeOneTimePreKey(id);
      }
      for (final id in kyber.keys.toList()) {
        await restarted.consumeKyberPreKey(id);
      }
      restarted = SignalClient(storage);
      final bundle =
          await restarted.resumeInitialKeys(otpkCount: 2, kyberCount: 2);
      expect(bundle.oneTimePreKeys.map((key) => key.id), [6, 7]);
      expect(bundle.kyberPreKeys.map((key) => key.id), [6, 7]);
      expect(identity!.serialized, originalIdentity);
      verifyNever(() => storage.wipe());
    });

    test('resumes after an identity-only write using the same private identity',
        () async {
      failSignedWrite = true;
      await expectLater(
          SignalClient(storage).resumeInitialKeys(otpkCount: 3, kyberCount: 2),
          throwsStateError);
      final savedIdentity = identity!.serialized.toList();
      final bundle = await SignalClient(storage)
          .resumeInitialKeys(otpkCount: 3, kyberCount: 2);
      expect(identity!.serialized, savedIdentity);
      expect(bundle.identityPublic, identity!.publicKey);
      expect(bundle.oneTimePreKeys, hasLength(3));
      expect(bundle.kyberPreKeys, hasLength(2));
      expect(
          verifySignedPrekey(
              identityPublic: bundle.identityPublic,
              signedPrekeyPublic: bundle.signedPreKey.public,
              signature: bundle.signedPreKey.signature),
          isTrue);
      verify(() => storage.saveIdentityKeyPair(any())).called(1);
      verifyNever(() => storage.wipe());
    });

    test('resumes a partial Kyber batch without replacing earlier key records',
        () async {
      failSecondKyberWrite = true;
      await expectLater(
          SignalClient(storage).resumeInitialKeys(otpkCount: 3, kyberCount: 3),
          throwsStateError);
      final oldIdentity = identity!.serialized.toList();
      final oldSigned = signed!.serialized.toList();
      final oldKyber = kyber[1]!.serialized.toList();
      final bundle = await SignalClient(storage)
          .resumeInitialKeys(otpkCount: 3, kyberCount: 3);
      expect(identity!.serialized, oldIdentity);
      expect(signed!.serialized, oldSigned);
      expect(kyber[1]!.serialized, oldKyber);
      // The interrupted batch reserved IDs 1–3. Resume past that range.
      expect(bundle.kyberPreKeys.map((key) => key.id).toSet(), {1, 4, 5});
      verifyNever(() => storage.wipe());
    });
    test(
        'prekey conflict recovery preserves private records and resumes after restart',
        () async {
      final client = SignalClient(storage);
      await client.resumeInitialKeys(otpkCount: 3, kyberCount: 3);
      final oldIdentity = identity!.serialized.toList();
      final oldSigned = signed!.serialized.toList();
      final oldOne = otpks[1]!.serialized.toList();
      final oldKyber = kyber[1]!.serialized.toList();
      await client.preparePrekeyRecovery(100, 50);
      expect(await client.prekeyRecoveryPending(), isTrue);
      final restarted = SignalClient(storage);
      final fresh =
          await restarted.resumeInitialKeys(otpkCount: 3, kyberCount: 3);
      expect(fresh.oneTimePreKeys.map((key) => key.id), [101, 102, 103]);
      expect(fresh.kyberPreKeys.map((key) => key.id), [51, 52, 53]);
      expect(identity!.serialized, oldIdentity);
      expect(signed!.serialized, oldSigned);
      expect(otpks[1]!.serialized, oldOne);
      expect(kyber[1]!.serialized, oldKyber);
      await restarted.completePrekeyRecovery();
      final reopened = SignalClient(storage);
      expect(await reopened.prekeyRecoveryPending(), isFalse);
      expect(
          (await reopened.currentPublicBundle())!
              .oneTimePreKeys
              .map((key) => key.id),
          [101, 102, 103]);
      verifyNever(() => storage.wipe());
    });
  },
      skip: library == null
          ? 'Set ASIDE_CRYPTO_TEST_LIBRARY to the native test library'
          : false);
}
