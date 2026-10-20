// Pure-Dart unit tests for [KeyRegistrySync]. Mocks both the
// local crypto client (so no FFI) and the remote API service (so no
// network). Covers the orchestration logic end to end: bootstrap,
// replenishment, rotation, reset.

import 'dart:typed_data';
import 'dart:async';
import 'package:dio/dio.dart';

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
    when(() => signal.keyOwner()).thenAnswer((_) async => 'owner');
    when(() => signal.setKeyOwner(any())).thenAnswer((_) async {});
    when(() => signal.currentPublicBundle())
        .thenAnswer((_) async => _fakeBundle());
    when(() => signal.resumeInitialKeys(otpkCount: any(named: 'otpkCount')))
        .thenAnswer((_) async => _fakeBundle());
    when(() => api.uploadDeviceKeys(any())).thenAnswer((_) async {});
  });

  group('ensureKeysInitialized', () {
    test('generates + uploads when no keys exist', () async {
      final bundle = _fakeBundle();
      when(() => signal.hasKeys()).thenAnswer((_) async => false);
      when(() => signal.generateInitialKeys(otpkCount: any(named: 'otpkCount')))
          .thenAnswer((_) async => bundle);
      when(() => api.uploadDeviceKeys(any())).thenAnswer((_) async {});

      final created = await sync.ensureKeysInitialized(ownerUserId: 'owner');

      expect(created, isTrue);
      verify(() => signal.resumeInitialKeys(otpkCount: 100)).called(1);
      final captured =
          verify(() => api.uploadDeviceKeys(captureAny())).captured;
      expect(captured.single, {
        ...bundle.toJson(),
        'owner_user_id': 'owner',
        'existing_only': false
      });
      verifyNever(() => signal.wipeKeys());
    });

    test(
        'reconciles existing keys instead of treating presence as an upload receipt',
        () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => true);

      final created = await sync.ensureKeysInitialized(ownerUserId: 'owner');

      expect(created, isFalse);
      verifyNever(
          () => signal.generateInitialKeys(otpkCount: any(named: 'otpkCount')));
      verify(() => api.uploadDeviceKeys(any())).called(1);
    });

    test('preserves local keys if upload fails, then rethrows', () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => false);
      when(() => signal.generateInitialKeys(otpkCount: any(named: 'otpkCount')))
          .thenAnswer((_) async => _fakeBundle());
      when(() => api.uploadDeviceKeys(any()))
          .thenThrow(Exception('network down'));
      when(() => signal.wipeKeys()).thenAnswer((_) async {});

      await expectLater(
        () => sync.ensureKeysInitialized(ownerUserId: 'owner'),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => signal.wipeKeys());
      verifyNever(() => api.revokeDeviceKeys());
    });

    test('custom otpkCount is plumbed through to SignalClient', () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => false);
      when(() => signal.generateInitialKeys(otpkCount: any(named: 'otpkCount')))
          .thenAnswer((_) async => _fakeBundle(otpkCount: 3));
      when(() => api.uploadDeviceKeys(any())).thenAnswer((_) async {});

      await sync.ensureKeysInitialized(ownerUserId: 'owner', otpkCount: 25);

      verify(() => signal.resumeInitialKeys(otpkCount: 25)).called(1);
    });

    test(
        'retry after a lost reply reuses the saved bundle without generating an identity',
        () async {
      var existed = false;
      final saved = _fakeBundle();
      when(() => signal.hasKeys()).thenAnswer((_) async => existed);
      when(() => signal.resumeInitialKeys(otpkCount: any(named: 'otpkCount')))
          .thenAnswer((_) async {
        existed = true;
        return saved;
      });
      when(() => signal.currentPublicBundle()).thenAnswer((_) async => saved);
      var calls = 0;
      when(() => api.uploadDeviceKeys(any())).thenAnswer((_) async {
        if (++calls == 1) {
          throw DioException(
              requestOptions: RequestOptions(path: '/fixture'),
              type: DioExceptionType.receiveTimeout);
        }
      });
      await expectLater(sync.ensureKeysInitialized(ownerUserId: 'owner'),
          throwsA(isA<DioException>()));
      expect(await sync.ensureKeysInitialized(ownerUserId: 'owner'), isFalse);
      final sent = verify(() => api.uploadDeviceKeys(captureAny())).captured;
      expect(sent[0], sent[1]);
      verify(() => signal.resumeInitialKeys(otpkCount: 100)).called(1);
      verifyNever(() => signal.wipeKeys());
    });

    test('coalesces concurrent bootstrap calls', () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => true);
      final uploaded = Completer<void>();
      when(() => api.uploadDeviceKeys(any()))
          .thenAnswer((_) => uploaded.future);
      final first = sync.ensureKeysInitialized(ownerUserId: 'owner');
      final second = sync.ensureKeysInitialized(ownerUserId: 'owner');
      uploaded.complete();
      await Future.wait([first, second]);
      verify(() => api.uploadDeviceKeys(any())).called(1);
    });

    test('two wrappers for the same local client share provisioning work',
        () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => true);
      final second = KeyRegistrySync(signal, api);
      await Future.wait([
        sync.ensureKeysInitialized(ownerUserId: 'owner'),
        second.ensureKeysInitialized(ownerUserId: 'owner'),
      ]);
      verify(() => api.uploadDeviceKeys(any())).called(1);
    });

    test('a different local owner fails without publishing or deleting keys',
        () async {
      await expectLater(sync.ensureKeysInitialized(ownerUserId: 'someone-else'),
          throwsA(isA<KeyRecoveryRequired>()));
      verifyNever(() => api.uploadDeviceKeys(any()));
      verifyNever(() => signal.setKeyOwner(any()));
      verifyNever(() => signal.wipeKeys());
    });

    test(
        'legacy keys are bound only after existing-only reconciliation succeeds',
        () async {
      when(() => signal.keyOwner()).thenAnswer((_) async => null);
      when(() => signal.hasKeys()).thenAnswer((_) async => true);
      when(() => api.uploadDeviceKeys(any())).thenAnswer((invocation) async {
        expect((invocation.positionalArguments.single as Map)['existing_only'],
            isTrue);
      });
      await sync.ensureKeysInitialized(ownerUserId: 'owner');
      verifyInOrder([
        () => api.uploadDeviceKeys(any()),
        () => signal.setKeyOwner('owner'),
      ]);
    });

    test('a legacy conflict cannot bind, replace, revoke, or wipe an identity',
        () async {
      when(() => signal.keyOwner()).thenAnswer((_) async => null);
      when(() => signal.hasKeys()).thenAnswer((_) async => true);
      final request = RequestOptions(path: '/fixture');
      when(() => api.uploadDeviceKeys(any())).thenThrow(DioException(
          requestOptions: request,
          response: Response(requestOptions: request, statusCode: 409)));
      await expectLater(sync.ensureKeysInitialized(ownerUserId: 'owner'),
          throwsA(isA<DioException>()));
      verifyNever(() => signal.setKeyOwner(any()));
      verifyNever(
          () => signal.resumeInitialKeys(otpkCount: any(named: 'otpkCount')));
      verifyNever(() => api.revokeDeviceKeys());
      verifyNever(() => signal.wipeKeys());
    });

    test('owned partial generation resumes without deleting the saved identity',
        () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => true);
      when(() => signal.currentPublicBundle()).thenAnswer((_) async => null);
      await sync.ensureKeysInitialized(ownerUserId: 'owner');
      verify(() => signal.resumeInitialKeys(otpkCount: 100)).called(1);
      verifyNever(() => signal.wipeKeys());
    });

    test(
        'an incomplete unregistered bundle is resumed only on the fixed server code',
        () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => true);
      var calls = 0;
      when(() => api.uploadDeviceKeys(any())).thenAnswer((_) async {
        if (++calls == 1) {
          final request = RequestOptions(path: '/fixture');
          throw DioException(
              requestOptions: request,
              response: Response(
                  requestOptions: request,
                  statusCode: 400,
                  data: {'code': 'key_bundle_incomplete'}));
        }
      });
      await sync.ensureKeysInitialized(ownerUserId: 'owner');
      expect(calls, 2);
      verify(() => signal.resumeInitialKeys(otpkCount: 100)).called(1);
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
            ownerUserId: any(named: 'ownerUserId'),
            identityKey: any(named: 'identityKey'),
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
            ownerUserId: any(named: 'ownerUserId'),
            identityKey: any(named: 'identityKey'),
            oneTimePreKeys: any(named: 'oneTimePreKeys'),
            kyberPreKeys: any(named: 'kyberPreKeys'),
          )).thenAnswer((_) async {});

      final result = await sync.replenishIfNeeded();

      expect(result.otpks, 2);
      expect(result.kyber, 1);
      final captured = verify(() => api.replenishPreKeys(
            ownerUserId: any(named: 'ownerUserId'),
            identityKey: any(named: 'identityKey'),
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
            ownerUserId: any(named: 'ownerUserId'),
            identityKey: any(named: 'identityKey'),
            oneTimePreKeys: any(named: 'oneTimePreKeys'),
            kyberPreKeys: any(named: 'kyberPreKeys'),
          )).thenAnswer((_) async {});

      final result = await sync.replenishIfNeeded();

      expect(result.otpks, 1);
      expect(result.kyber, 0);
      // Upload still happens, but with empty kyberPreKeys list.
      final captured = verify(() => api.replenishPreKeys(
            ownerUserId: any(named: 'ownerUserId'),
            identityKey: any(named: 'identityKey'),
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

    test('retains and retries the same private prekeys after an upload failure',
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
            ownerUserId: any(named: 'ownerUserId'),
            identityKey: any(named: 'identityKey'),
            oneTimePreKeys: any(named: 'oneTimePreKeys'),
            kyberPreKeys: any(named: 'kyberPreKeys'),
          )).thenThrow(Exception('network down'));
      when(() => signal.consumeOneTimePreKey(any())).thenAnswer((_) async {});
      when(() => signal.consumeKyberPreKey(any())).thenAnswer((_) async {});

      await expectLater(
        () => sync.replenishIfNeeded(),
        throwsA(isA<Exception>()),
      );

      verifyNever(() => signal.consumeOneTimePreKey(any()));
      verifyNever(() => signal.consumeKyberPreKey(any()));
      when(() => api.replenishPreKeys(
            ownerUserId: any(named: 'ownerUserId'),
            identityKey: any(named: 'identityKey'),
            oneTimePreKeys: any(named: 'oneTimePreKeys'),
            kyberPreKeys: any(named: 'kyberPreKeys'),
          )).thenAnswer((_) async {});
      await sync.replenishIfNeeded();
      verify(() => signal.replenishOneTimePreKeys(
          threshold: any(named: 'threshold'),
          batchSize: any(named: 'batchSize'))).called(1);
      verify(() => signal.replenishKyberPreKeys(
          threshold: any(named: 'threshold'),
          batchSize: any(named: 'batchSize'))).called(1);
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
    test('waits for pending registration before revoking and wiping', () async {
      when(() => signal.hasKeys()).thenAnswer((_) async => true);
      final upload = Completer<void>();
      when(() => api.uploadDeviceKeys(any())).thenAnswer((_) => upload.future);
      when(() => api.revokeDeviceKeys()).thenAnswer((_) async {});
      when(() => signal.wipeKeys()).thenAnswer((_) async {});
      final registration = sync.ensureKeysInitialized(ownerUserId: 'owner');
      await Future<void>.delayed(Duration.zero);
      final reset = sync.resetKeys();
      verifyNever(() => api.revokeDeviceKeys());
      await expectLater(
          sync.ensureKeysInitialized(ownerUserId: 'owner'), throwsStateError);
      upload.complete();
      await Future.wait([registration, reset]);
      verifyInOrder([
        () => api.uploadDeviceKeys(any()),
        () => api.revokeDeviceKeys(),
        () => signal.wipeKeys(),
      ]);
    });
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

    test('wipes locally when server revocation fails', () async {
      when(() => api.revokeDeviceKeys())
          .thenThrow(Exception('server unavailable'));
      when(() => signal.wipeKeys()).thenAnswer((_) async {});

      await expectLater(sync.resetKeys(), throwsException);

      verify(() => signal.wipeKeys()).called(1);
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
