// Pure-Dart unit tests for [KeyRegistrySync]. Mocks both the
// local crypto client (so no FFI) and the remote API service (so no
// network). Covers the orchestration logic end to end: bootstrap,
// replenishment, rotation, reset.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:aside/core/crypto/key_registry_sync.dart';
import 'package:aside/core/crypto/signal_client.dart';
import 'package:aside/core/network/api_service.dart';

class _MockSignalClient extends Mock implements SignalClient {}

class _MockApiService extends Mock implements ApiService {}

PublicKeyBundle _fakeBundle({int otpkCount = 5, int kyberCount = 2}) {
  return PublicKeyBundle(
    identityPublic: Uint8List.fromList(List.generate(33, (i) => i)),
    signedPreKey: PublicSignedPreKey(
      id: 1,
      public: Uint8List.fromList(List.generate(33, (i) => i + 100)),
      signature: Uint8List.fromList(List.generate(64, (i) => i + 200)),
    ),
    oneTimePreKeys: List.generate(
      otpkCount,
      (i) => PublicOneTimePreKey(
        id: i + 1,
        public:
            Uint8List.fromList(List.generate(33, (j) => (i * 31 + j) % 256)),
      ),
    ),
    kyberPreKeys: List.generate(
      kyberCount,
      (i) => PublicKyberPreKey(
        id: i + 1,
        public:
            Uint8List.fromList(List.generate(1568, (j) => (i * 7 + j) % 256)),
        signature:
            Uint8List.fromList(List.generate(64, (j) => (i * 17 + j) % 256)),
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    // mocktail needs fallback values for non-null typed args. Both the
    // bundle's toJson and the list-of-maps replenish payload are Maps.
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(<Map<String, dynamic>>[]);
  });

  late _MockSignalClient signal;
  late _MockApiService api;
  late KeyRegistrySync sync;

  setUp(() {
    signal = _MockSignalClient();
    api = _MockApiService();
    sync = KeyRegistrySync(signal, api);
  });

  group('ensureKeysInitialized', () {
    test('generates + uploads when no keys exist', () async {
      final bundle = _fakeBundle();
      when(() => signal.hasKeys()).thenAnswer((_) async => false);
      when(() => signal.generateInitialKeys(otpkCount: any(named: 'otpkCount')))
          .thenAnswer((_) async => bundle);
      when(() => api.uploadDeviceKeys(any())).thenAnswer((_) async {});

      final created = await sync.ensureKeysInitialized();

      expect(created, isTrue);
      verify(() => signal.generateInitialKeys(otpkCount: 100)).called(1);
      final captured =
          verify(() => api.uploadDeviceKeys(captureAny())).captured;
      expect(captured.single, bundle.toJson());
      verifyNever(() => signal.wipeKeys());
    });

    test('returns false and skips everything when keys exist', () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => true);

      final created = await sync.ensureKeysInitialized();

      expect(created, isFalse);
      verifyNever(
          () => signal.generateInitialKeys(otpkCount: any(named: 'otpkCount')));
      verifyNever(() => api.uploadDeviceKeys(any()));
    });

    test('wipes local keys if upload fails, then rethrows', () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => false);
      when(() => signal.generateInitialKeys(otpkCount: any(named: 'otpkCount')))
          .thenAnswer((_) async => _fakeBundle());
      when(() => api.uploadDeviceKeys(any()))
          .thenThrow(Exception('network down'));
      when(() => signal.wipeKeys()).thenAnswer((_) async {});

      await expectLater(
        () => sync.ensureKeysInitialized(),
        throwsA(isA<Exception>()),
      );
      verify(() => signal.wipeKeys()).called(1);
    });

    test('custom otpkCount is plumbed through to SignalClient', () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => false);
      when(() => signal.generateInitialKeys(otpkCount: any(named: 'otpkCount')))
          .thenAnswer((_) async => _fakeBundle(otpkCount: 3));
      when(() => api.uploadDeviceKeys(any())).thenAnswer((_) async {});

      await sync.ensureKeysInitialized(otpkCount: 25);

      verify(() => signal.generateInitialKeys(otpkCount: 25)).called(1);
    });
  });

  group('replenishIfNeeded', () {
    test('no-op when SignalClient reports nothing to do on either pool',
        () async {
      when(() => signal.replenishOneTimePreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => const []);
      when(() => signal.replenishKyberPreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => const []);

      final result = await sync.replenishIfNeeded();

      expect(result.otpks, 0);
      expect(result.kyber, 0);
      verifyNever(() => api.replenishPreKeys(
            oneTimePreKeys: any(named: 'oneTimePreKeys'),
            kyberPreKeys: any(named: 'kyberPreKeys'),
          ));
    });

    test('uploads the freshly generated OTPKs and Kyber together', () async {
      final freshOtpks = [
        PublicOneTimePreKey(
          id: 21,
          public: Uint8List.fromList(List.generate(33, (i) => i)),
        ),
        PublicOneTimePreKey(
          id: 22,
          public: Uint8List.fromList(List.generate(33, (i) => i + 10)),
        ),
      ];
      final freshKyber = [
        PublicKyberPreKey(
          id: 5,
          public: Uint8List.fromList(List.generate(1568, (i) => i % 256)),
          signature: Uint8List.fromList(List.generate(64, (i) => i + 50)),
        ),
      ];
      when(() => signal.replenishOneTimePreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => freshOtpks);
      when(() => signal.replenishKyberPreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => freshKyber);
      when(() => api.replenishPreKeys(
            oneTimePreKeys: any(named: 'oneTimePreKeys'),
            kyberPreKeys: any(named: 'kyberPreKeys'),
          )).thenAnswer((_) async {});

      final result = await sync.replenishIfNeeded();

      expect(result.otpks, 2);
      expect(result.kyber, 1);
      final captured = verify(() => api.replenishPreKeys(
            oneTimePreKeys: captureAny(named: 'oneTimePreKeys'),
            kyberPreKeys: captureAny(named: 'kyberPreKeys'),
          )).captured;
      final otpkPayload = captured[0] as List<Map<String, dynamic>>;
      final kyberPayload = captured[1] as List<Map<String, dynamic>>;
      expect(otpkPayload.length, 2);
      expect(kyberPayload.length, 1);
      expect(kyberPayload.first['id'], 5);
      expect(kyberPayload.first['signature'], isNotNull);
      // Public-only: no private bytes leak through either list.
      expect(
        otpkPayload.every((m) => !m.containsKey('private')),
        isTrue,
      );
      expect(
        kyberPayload.every((m) => !m.containsKey('private')),
        isTrue,
      );
    });

    test('skips server call when only one pool is empty (still uploads)',
        () async {
      // OTPKs top up, Kyber still healthy.
      when(() => signal.replenishOneTimePreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => [
            PublicOneTimePreKey(
              id: 1,
              public: Uint8List.fromList(List.generate(33, (i) => i)),
            ),
          ]);
      when(() => signal.replenishKyberPreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => const []);
      when(() => api.replenishPreKeys(
            oneTimePreKeys: any(named: 'oneTimePreKeys'),
            kyberPreKeys: any(named: 'kyberPreKeys'),
          )).thenAnswer((_) async {});

      final result = await sync.replenishIfNeeded();

      expect(result.otpks, 1);
      expect(result.kyber, 0);
      // Upload still happens, but with empty kyberPreKeys list.
      final captured = verify(() => api.replenishPreKeys(
            oneTimePreKeys: captureAny(named: 'oneTimePreKeys'),
            kyberPreKeys: captureAny(named: 'kyberPreKeys'),
          )).captured;
      expect((captured[0] as List).length, 1);
      expect((captured[1] as List).length, 0);
    });

    test('passes through custom thresholds + batch sizes', () async {
      when(() => signal.replenishOneTimePreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => const []);
      when(() => signal.replenishKyberPreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => const []);

      await sync.replenishIfNeeded(
        otpkThreshold: 5,
        otpkBatchSize: 50,
        kyberThreshold: 2,
        kyberBatchSize: 10,
      );

      verify(() => signal.replenishOneTimePreKeys(threshold: 5, batchSize: 50))
          .called(1);
      verify(() => signal.replenishKyberPreKeys(threshold: 2, batchSize: 10))
          .called(1);
    });

    test('rolls back freshly persisted local prekeys if upload fails',
        () async {
      final freshOtpks = [
        PublicOneTimePreKey(
          id: 21,
          public: Uint8List.fromList(List.generate(33, (i) => i)),
        ),
      ];
      final freshKyber = [
        PublicKyberPreKey(
          id: 5,
          public: Uint8List.fromList(List.generate(1568, (i) => i % 256)),
          signature: Uint8List.fromList(List.generate(64, (i) => i + 50)),
        ),
      ];
      when(() => signal.replenishOneTimePreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => freshOtpks);
      when(() => signal.replenishKyberPreKeys(
            threshold: any(named: 'threshold'),
            batchSize: any(named: 'batchSize'),
          )).thenAnswer((_) async => freshKyber);
      when(() => api.replenishPreKeys(
            oneTimePreKeys: any(named: 'oneTimePreKeys'),
            kyberPreKeys: any(named: 'kyberPreKeys'),
          )).thenThrow(Exception('network down'));
      when(() => signal.consumeOneTimePreKey(any())).thenAnswer((_) async {});
      when(() => signal.consumeKyberPreKey(any())).thenAnswer((_) async {});

      await expectLater(
        () => sync.replenishIfNeeded(),
        throwsA(isA<Exception>()),
      );

      verify(() => signal.consumeOneTimePreKey(21)).called(1);
      verify(() => signal.consumeKyberPreKey(5)).called(1);
    });
  });

  group('rotateSignedPreKey', () {
    test('generates new SPK locally and uploads it', () async {
      final spk = PublicSignedPreKey(
        id: 2,
        public: Uint8List.fromList(List.generate(33, (i) => i * 2 % 256)),
        signature: Uint8List.fromList(List.generate(64, (i) => i + 50)),
      );
      when(() => signal.rotateSignedPreKey()).thenAnswer((_) async => spk);
      when(() => api.rotateSignedPreKey(any())).thenAnswer((_) async {});

      await sync.rotateSignedPreKey();

      verify(() => signal.rotateSignedPreKey()).called(1);
      final captured =
          verify(() => api.rotateSignedPreKey(captureAny())).captured;
      expect(captured.single, spk.toJson());
    });
  });

  group('resetKeys', () {
    test('revokes on server then wipes locally', () async {
      when(() => api.revokeDeviceKeys()).thenAnswer((_) async {});
      when(() => signal.wipeKeys()).thenAnswer((_) async {});

      await sync.resetKeys();

      // Server must come first so local wipe failure doesn't leave
      // the server with a stale-but-active key set.
      verifyInOrder([
        () => api.revokeDeviceKeys(),
        () => signal.wipeKeys(),
      ]);
    });
  });

  group('fetchPeerKeyBundle', () {
    test('passes through to ApiService', () async {
      final payload = {
        'identity_key_pub': 'abc',
        'signed_prekey': {'id': 1, 'public': 'def', 'signature': 'ghi'},
        'one_time_prekey': {'id': 5, 'public': 'jkl'},
      };
      when(() => api.getUserKeyBundle('user-42'))
          .thenAnswer((_) async => payload);

      final result = await sync.fetchPeerKeyBundle('user-42');
      expect(result, same(payload));
    });
  });
}
