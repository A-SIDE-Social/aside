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
    var failSignedWrite = false;
    var failSecondKyberWrite = false;
    setUpAll(() async {
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
      identity = null;
      signed = null;
      otpks = {};
      kyber = {};
      failSignedWrite = false;
      failSecondKyberWrite = false;
      when(() => storage.loadIdentityKeyPair())
          .thenAnswer((_) async => identity);
      when(() => storage.loadSignedPreKey()).thenAnswer((_) async => signed);
      when(() => storage.listOneTimePreKeyIds())
          .thenAnswer((_) async => otpks.keys.toList());
      when(() => storage.listKyberPreKeyIds())
          .thenAnswer((_) async => kyber.keys.toList());
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
        otpks[key.id] = key;
      });
      when(() => storage.saveKyberPreKey(any())).thenAnswer((i) async {
        if (failSecondKyberWrite && kyber.length == 1) {
          failSecondKyberWrite = false;
          throw StateError('Simulated interrupted write');
        }
        final key = i.positionalArguments.single as KyberPreKey;
        kyber[key.id] = key;
      });
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
      expect(bundle.kyberPreKeys.map((key) => key.id).toSet(), {1, 2, 3});
      verifyNever(() => storage.wipe());
    });
  },
      skip: library == null
          ? 'Set ASIDE_CRYPTO_TEST_LIBRARY to the native test library'
          : false);
}
