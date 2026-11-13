import 'dart:convert';
import 'dart:io';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aside/core/crypto/signal_client.dart';
import 'package:aside/src/rust/frb_generated.dart';
import '../../../helpers/in_memory_key_storage.dart';

PeerKeyBundle peerBundle(PublicKeyBundle value) =>
    PeerKeyBundle.fromServerJson({
      ...value.toJson(),
      'one_time_prekey': value.oneTimePreKeys.first.toJson(),
      'kyber_prekey': value.kyberPreKeys.first.toJson(),
    });

void main() {
  final library = Platform.environment['ASIDE_CRYPTO_TEST_LIBRARY'];
  test(
      'a peer refreshes a moved identity and redistributes group keys without wiping history',
      () async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
    final oldStore = InMemoryKeyStorage();
    final newStore = InMemoryKeyStorage();
    final peerStore = InMemoryKeyStorage();
    final oldPhone = SignalClient(oldStore);
    final newPhone = SignalClient(newStore);
    final peer = SignalClient(peerStore);
    final oldBundle =
        await oldPhone.generateInitialKeys(otpkCount: 3, kyberCount: 3);
    final newBundle =
        await newPhone.generateInitialKeys(otpkCount: 3, kyberCount: 3);
    await peer.generateInitialKeys(otpkCount: 3, kyberCount: 3);
    await peer.startSessionWithPeer(
        'peer', 'moving-user', peerBundle(oldBundle));
    final old = await peer.encryptMessageFor('peer', 'moving-user',
        Uint8List.fromList(utf8.encode('before transfer')));
    expect(
        utf8.decode(await oldPhone.decryptMessageFrom(
            'moving-user', 'peer', old.messageType, old.ciphertext)),
        'before transfer');
    await peerStore.savePlaintext('old-message', 'before transfer');
    const groupId = 'b60b7c7e-4312-4ccc-884f-bf430c94e6a9';
    final oldSkdm = await peer.ensureOwnGroupSenderKey(
        ownUserId: 'peer', conversationId: groupId, currentEpoch: 0);
    expect(oldSkdm, isNotNull);
    var fetches = 0;
    final changed =
        await peer.ensureSessionWithPeer('peer', 'moving-user', () async {
      fetches++;
      return peerBundle(newBundle);
    }, fetchIdentity: () async => base64.encode(newBundle.identityPublic));
    expect(changed?.identityChanged, isTrue);
    final freshSkdm = await peer.ensureOwnGroupSenderKey(
        ownUserId: 'peer', conversationId: groupId, currentEpoch: 1);
    expect(freshSkdm, isNotNull);
    final wrapped =
        await peer.encryptMessageFor('peer', 'moving-user', freshSkdm!);
    final received = await newPhone.decryptMessageFrom(
        'moving-user', 'peer', wrapped.messageType, wrapped.ciphertext);
    expect(received, freshSkdm);
    await newPhone.processGroupSenderKeyFrom(
        senderUserId: 'peer', conversationId: groupId, skdmBytes: received);
    final groupCiphertext = await peer.encryptGroupMessage(
        ownUserId: 'peer',
        conversationId: groupId,
        plaintext: Uint8List.fromList(utf8.encode('after transfer')));
    expect(
        utf8.decode(await newPhone.decryptGroupMessage(
            senderUserId: 'peer',
            conversationId: groupId,
            ciphertext: groupCiphertext)),
        'after transfer');
    expect(await peerStore.loadPlaintext('old-message'), 'before transfer');
    expect((await newStore.loadIdentityKeyPair())!.publicKey,
        newBundle.identityPublic);
    expect((await oldStore.loadIdentityKeyPair())!.publicKey,
        oldBundle.identityPublic);
    // An unchanged identity checks metadata without consuming another bundle.
    await peer.ensureSessionWithPeer('peer', 'moving-user', () async {
      fetches++;
      return peerBundle(newBundle);
    }, fetchIdentity: () async => base64.encode(newBundle.identityPublic));
    expect(fetches, 1);
    await expectLater(
        newPhone.decryptMessageFrom(
            'moving-user', 'peer', old.messageType, old.ciphertext),
        throwsA(anything));
  },
      skip: library == null
          ? 'Set ASIDE_CRYPTO_TEST_LIBRARY to the native test library'
          : false);
}
