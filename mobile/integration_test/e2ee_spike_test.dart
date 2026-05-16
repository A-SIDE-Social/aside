// Phase 1a smoke test. Runs on-device so the Rust FFI is actually
// wired up — unlike `flutter test` which runs on the host Dart VM
// without native libs. Verifies:
//   1. RustLib.init() succeeds (the dynamic library loads)
//   2. cryptoVersion() returns the expected sentinel string
//   3. generateIdentityKeypair() returns a protobuf-serialized blob
//      and a 33-byte public key (libsignal's DJB-type-byte + 32)
//   4. identityPublicFromSerialized() reproduces the public half
//      from the serialized keypair — round-trip across FFI
//
// Run: `flutter test integration_test/e2ee_spike_test.dart -d <device>`

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:aside/src/rust/api/identity.dart';
import 'package:aside/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('version sentinel reaches Dart intact', (_) async {
    final v = cryptoVersion();
    expect(v, contains('aside_crypto'));
    expect(v, contains('libsignal-protocol'));
  });

  testWidgets('generateIdentityKeypair returns expected byte shapes',
      (_) async {
    final kp = generateIdentityKeypair();
    // libsignal IdentityKey = 1-byte DJB type marker + 32 bytes Curve25519
    expect(kp.publicKey.length, 33);
    // serialized is the protobuf form of the full keypair — at least
    // larger than the public key alone.
    expect(kp.serialized.length, greaterThan(kp.publicKey.length));
  });

  testWidgets('two calls produce different keypairs (OS RNG live)', (_) async {
    final a = generateIdentityKeypair();
    final b = generateIdentityKeypair();
    expect(listEquals(a.publicKey, b.publicKey), isFalse);
    expect(listEquals(a.serialized, b.serialized), isFalse);
  });

  testWidgets('identity round-trip: serialized keypair re-derives public key',
      (_) async {
    final kp = generateIdentityKeypair();
    final rt = identityPublicFromSerialized(serialized: kp.serialized);
    expect(rt.length, 33);
    expect(listEquals(rt, kp.publicKey), isTrue,
        reason: 'identityPublicFromSerialized must return the same '
            'public key that was generated alongside the serialized blob');
  });
}
