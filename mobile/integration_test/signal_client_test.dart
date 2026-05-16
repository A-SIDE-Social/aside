// Phase 1b: on-device tests of the SignalClient key lifecycle.
//
// Covers:
//   - First-run key generation (identity + signed prekey + OTPK batch)
//   - Persistence across a fresh SignalClient instance (Keychain /
//     Keystore round-trip)
//   - Signed prekey signature verification (Rust-side Ed25519 check)
//   - Signed prekey rotation increments id + generates new material
//   - OTPK replenishment respects the threshold and ids continue past
//     the previous max
//   - consumeOneTimePreKey removes the record and shrinks the index
//   - wipeKeys clears everything
//   - Public bundle JSON shape matches the server's expected upload body
//
// Run:
//   flutter test integration_test/signal_client_test.dart -d <device>

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:aside/core/crypto/key_storage.dart';
import 'package:aside/core/crypto/signal_client.dart';
import 'package:aside/src/rust/api/prekeys.dart';
import 'package:aside/src/rust/frb_generated.dart';

/// Fresh storage for each test. flutter_secure_storage persists across
/// test invocations within the same app, so every test starts by
/// wiping the e2ee:* namespace.
Future<SignalClient> _freshClient() async {
  const storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  final keyStorage = SecureKeyStorage(storage: storage);
  final client = SignalClient(keyStorage);
  await client.initialize();
  await client.wipeKeys();
  return client;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets(
      'generateInitialKeys produces identity + spk + 100 OTPKs + 20 Kyber',
      (_) async {
    final client = await _freshClient();

    expect(await client.hasKeys(), isFalse);
    final bundle = await client.generateInitialKeys();

    expect(await client.hasKeys(), isTrue);
    expect(bundle.identityPublic.length, 33);
    expect(bundle.signedPreKey.id, 1);
    expect(bundle.signedPreKey.public.length, 33);
    expect(bundle.signedPreKey.signature.length, 64);
    expect(bundle.oneTimePreKeys.length, 100);
    expect(bundle.oneTimePreKeys.first.id, 1);
    expect(bundle.oneTimePreKeys.last.id, 100);
    expect(bundle.oneTimePreKeys.every((k) => k.public.length == 33), isTrue);

    // Kyber defaults: 20 entries, ~1568-byte public keys, 64-byte
    // Ed25519 signatures.
    expect(bundle.kyberPreKeys.length, 20);
    expect(bundle.kyberPreKeys.first.id, 1);
    expect(bundle.kyberPreKeys.last.id, 20);
    expect(
      bundle.kyberPreKeys.every((k) => k.public.length > 1500),
      isTrue,
    );
    expect(
      bundle.kyberPreKeys.every((k) => k.signature.length == 64),
      isTrue,
    );
  });

  testWidgets('initial call throws if keys already exist', (_) async {
    final client = await _freshClient();
    await client.generateInitialKeys();
    expect(
      () => client.generateInitialKeys(),
      throwsA(isA<StateError>()),
    );
  });

  testWidgets('keys persist across SignalClient instances', (_) async {
    final c1 = await _freshClient();
    final original = await c1.generateInitialKeys();

    // Simulate app restart: fresh SignalClient against same storage.
    const storage = FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    final c2 = SignalClient(SecureKeyStorage(storage: storage));
    await c2.initialize();

    expect(await c2.hasKeys(), isTrue);
    final restored = await c2.currentPublicBundle();
    expect(restored, isNotNull);
    expect(restored!.identityPublic, equals(original.identityPublic));
    expect(restored.signedPreKey.id, original.signedPreKey.id);
    expect(restored.signedPreKey.public, equals(original.signedPreKey.public));
    expect(restored.oneTimePreKeys.length, 100);
    expect(restored.kyberPreKeys.length, 20);
  });

  testWidgets('signed prekey signature verifies against identity key',
      (_) async {
    final client = await _freshClient();
    final bundle = await client.generateInitialKeys();

    final ok = verifySignedPrekey(
      identityPublic: bundle.identityPublic,
      signedPrekeyPublic: bundle.signedPreKey.public,
      signature: bundle.signedPreKey.signature,
    );
    expect(ok, isTrue);

    // Negative control: corrupt the signature, expect false.
    final tampered = List<int>.from(bundle.signedPreKey.signature);
    tampered[0] ^= 0xff;
    final bad = verifySignedPrekey(
      identityPublic: bundle.identityPublic,
      signedPrekeyPublic: bundle.signedPreKey.public,
      signature: tampered,
    );
    expect(bad, isFalse);
  });

  testWidgets('rotateSignedPreKey bumps id and produces new material',
      (_) async {
    final client = await _freshClient();
    final initial = await client.generateInitialKeys();

    final rotated = await client.rotateSignedPreKey();
    expect(rotated.id, initial.signedPreKey.id + 1);
    expect(rotated.public, isNot(equals(initial.signedPreKey.public)));
    expect(rotated.signature, isNot(equals(initial.signedPreKey.signature)));

    // New signature still verifies.
    final ok = verifySignedPrekey(
      identityPublic: initial.identityPublic,
      signedPrekeyPublic: rotated.public,
      signature: rotated.signature,
    );
    expect(ok, isTrue);
  });

  testWidgets('replenish is a no-op above threshold', (_) async {
    final client = await _freshClient();
    await client.generateInitialKeys();
    final result = await client.replenishOneTimePreKeys(threshold: 20);
    expect(result, isEmpty);
  });

  testWidgets('replenish tops up below threshold with contiguous ids',
      (_) async {
    final client = await _freshClient();
    final initial = await client.generateInitialKeys(otpkCount: 10);

    // Consume 9, leaving only 1 — below threshold=20.
    for (final otpk in initial.oneTimePreKeys.take(9)) {
      await client.consumeOneTimePreKey(otpk.id);
    }

    final fresh = await client.replenishOneTimePreKeys(
      threshold: 20,
      batchSize: 50,
    );
    expect(fresh.length, 50);
    // New ids start past the previous max (10).
    expect(fresh.first.id, 11);
    expect(fresh.last.id, 60);
  });

  testWidgets('consumeOneTimePreKey removes the record', (_) async {
    final client = await _freshClient();
    final bundle = await client.generateInitialKeys(otpkCount: 5);
    final targetId = bundle.oneTimePreKeys[2].id;

    await client.consumeOneTimePreKey(targetId);
    final after = await client.currentPublicBundle();
    expect(after!.oneTimePreKeys.length, 4);
    expect(
      after.oneTimePreKeys.any((k) => k.id == targetId),
      isFalse,
    );
  });

  testWidgets('wipeKeys clears everything', (_) async {
    final client = await _freshClient();
    await client.generateInitialKeys();
    await client.wipeKeys();

    expect(await client.hasKeys(), isFalse);
    expect(await client.currentPublicBundle(), isNull);
  });

  testWidgets('public bundle JSON matches server upload shape', (_) async {
    final client = await _freshClient();
    final bundle =
        await client.generateInitialKeys(otpkCount: 2, kyberCount: 2);
    final json = bundle.toJson();

    expect(json.containsKey('identity_key_pub'), isTrue);
    expect(json.containsKey('signed_prekey'), isTrue);
    expect(json.containsKey('one_time_prekeys'), isTrue);
    expect(json.containsKey('kyber_prekeys'), isTrue);
    expect((json['one_time_prekeys'] as List).length, 2);
    expect((json['kyber_prekeys'] as List).length, 2);

    // identity_key_pub is base64-encoded 33 bytes (libsignal format)
    final idBytes = base64.decode(json['identity_key_pub'] as String);
    expect(idBytes.length, 33);

    // signed_prekey has id/public/signature
    final spk = json['signed_prekey'] as Map<String, dynamic>;
    expect(spk['id'], isA<int>());
    expect(base64.decode(spk['public'] as String).length, 33);
    expect(base64.decode(spk['signature'] as String).length, 64);

    // Each OTPK has id + public (no private)
    for (final otpk
        in (json['one_time_prekeys'] as List).cast<Map<String, dynamic>>()) {
      expect(otpk['id'], isA<int>());
      expect(base64.decode(otpk['public'] as String).length, 33);
      expect(otpk.containsKey('private'), isFalse,
          reason: 'public bundle must not leak private keys');
    }

    // Each Kyber prekey has id + public + signature, no private.
    for (final kpk
        in (json['kyber_prekeys'] as List).cast<Map<String, dynamic>>()) {
      expect(kpk['id'], isA<int>());
      expect(
        base64.decode(kpk['public'] as String).length,
        greaterThan(1500),
      );
      expect(base64.decode(kpk['signature'] as String).length, 64);
      expect(kpk.containsKey('private'), isFalse,
          reason: 'public bundle must not leak Kyber private keys');
    }
  });

  testWidgets('Kyber replenishment tops up below threshold', (_) async {
    final client = await _freshClient();
    final initial =
        await client.generateInitialKeys(otpkCount: 2, kyberCount: 3);

    // Consume all but one Kyber so pool is below threshold=5.
    for (final k in initial.kyberPreKeys.take(2)) {
      await client.consumeKyberPreKey(k.id);
    }

    final fresh =
        await client.replenishKyberPreKeys(threshold: 5, batchSize: 4);
    expect(fresh.length, 4);
    // New ids start past the previous max (3).
    expect(fresh.first.id, 4);
    expect(fresh.last.id, 7);
    // Each has the expected shape.
    expect(
      fresh.every((k) => k.public.length > 1500 && k.signature.length == 64),
      isTrue,
    );
  });

  testWidgets('Kyber replenish is a no-op above threshold', (_) async {
    final client = await _freshClient();
    await client.generateInitialKeys(); // 20 Kyber → well above threshold=5
    final result = await client.replenishKyberPreKeys(threshold: 5);
    expect(result, isEmpty);
  });
}
