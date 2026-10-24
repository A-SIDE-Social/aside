import 'dart:convert';
import 'dart:io';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aside/core/crypto/signal_client.dart';
import 'package:aside/src/rust/frb_generated.dart';
import '../../../helpers/in_memory_key_storage.dart';

PeerKeyBundle peer(PublicKeyBundle b) => PeerKeyBundle(
      identityPublic: b.identityPublic,
      signedPreKeyId: b.signedPreKey.id,
      signedPreKeyPublic: b.signedPreKey.public,
      signedPreKeySignature: b.signedPreKey.signature,
      oneTimePreKeyId: b.oneTimePreKeys.first.id,
      oneTimePreKeyPublic: b.oneTimePreKeys.first.public,
      kyberPreKeyId: b.kyberPreKeys.first.id,
      kyberPreKeyPublic: b.kyberPreKeys.first.public,
      kyberPreKeySignature: b.kyberPreKeys.first.signature,
    );

void main() {
  final library = Platform.environment['ASIDE_CRYPTO_TEST_LIBRARY'];
  test(
      'repair decrypts delayed old-bundle messages and keeps established sessions',
      () async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
    final alice = SignalClient(InMemoryKeyStorage());
    final store = InMemoryKeyStorage();
    var bob = SignalClient(store);
    await alice.generateInitialKeys(otpkCount: 3, kyberCount: 3);
    final oldBundle =
        await bob.generateInitialKeys(otpkCount: 3, kyberCount: 3);
    await alice.startSessionWithPeer('alice', 'bob', peer(oldBundle));
    final delayed = await alice.encryptMessageFor(
        'alice', 'bob', Uint8List.fromList(utf8.encode('delayed')));
    await bob.preparePrekeyRecovery(100, 50);
    bob = SignalClient(store);
    final replacement =
        await bob.resumeInitialKeys(otpkCount: 3, kyberCount: 3);
    await bob.completePrekeyRecovery();
    expect(replacement.identityPublic, oldBundle.identityPublic);
    expect(replacement.signedPreKey.public, oldBundle.signedPreKey.public);
    expect(replacement.oneTimePreKeys.first.id, 101);
    final plaintext = await bob.decryptMessageFrom(
        'bob', 'alice', delayed.messageType, delayed.ciphertext);
    expect(utf8.decode(plaintext), 'delayed');
    final reply = await bob.encryptMessageFor(
        'bob', 'alice', Uint8List.fromList(utf8.encode('reply')));
    expect(
        utf8.decode(await alice.decryptMessageFrom(
            'alice', 'bob', reply.messageType, reply.ciphertext)),
        'reply');
    final session = await store.loadSession('alice');
    await bob.preparePrekeyRecovery(200, 100);
    bob = SignalClient(store);
    await bob.resumeInitialKeys(otpkCount: 3, kyberCount: 3);
    await bob.completePrekeyRecovery();
    expect(await store.loadSession('alice'), session);
    final next = await alice.encryptMessageFor(
        'alice', 'bob', Uint8List.fromList(utf8.encode('after repair')));
    expect(
        utf8.decode(await bob.decryptMessageFrom(
            'bob', 'alice', next.messageType, next.ciphertext)),
        'after repair');
    final charlie = SignalClient(InMemoryKeyStorage());
    await charlie.generateInitialKeys(otpkCount: 3, kyberCount: 3);
    await charlie.startSessionWithPeer(
        'charlie', 'bob', peer((await bob.currentPublicBundle())!));
    final fresh = await charlie.encryptMessageFor(
        'charlie', 'bob', Uint8List.fromList(utf8.encode('new contact')));
    expect(
        utf8.decode(await bob.decryptMessageFrom(
            'bob', 'charlie', fresh.messageType, fresh.ciphertext)),
        'new contact');
  },
      skip: library == null
          ? 'Set ASIDE_CRYPTO_TEST_LIBRARY to run native protocol tests'
          : false);
}
