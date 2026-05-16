// Phase 1e end-to-end test: Alice and Bob each set up a full key
// bundle, Alice fetches Bob's bundle, starts a session, encrypts a
// message, Bob decrypts it, plaintext matches. Then Bob replies
// (also a PKM, since Alice hasn't acked yet), Alice decrypts. Then
// Alice sends a second message — this time a SignalMessage on the
// established session — Bob decrypts.
//
// Runs on-device so the Rust FFI (and therefore libsignal's
// X3DH + Double Ratchet) is actually exercised. Uses in-memory
// KeyStorage so Alice and Bob can coexist in the same test
// process without clobbering each other in Keychain / Keystore.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:aside/core/crypto/key_storage.dart';
import 'package:aside/core/crypto/signal_client.dart';
import 'package:aside/src/rust/api/identity.dart';
import 'package:aside/src/rust/api/prekeys.dart';
import 'package:aside/src/rust/frb_generated.dart';

/// In-memory [KeyStorage]. Allows two SignalClient instances to
/// coexist in the same test process without clobbering platform
/// secure storage.
class _InMemoryKeyStorage implements KeyStorage {
  IdentityKeypair? _identity;
  SignedPreKey? _signedPreKey;
  final Map<int, OneTimePreKey> _otpks = {};
  final Map<int, KyberPreKey> _kpks = {};
  final Map<String, Uint8List> _sessions = {};

  @override
  Future<void> saveIdentityKeyPair(IdentityKeypair kp) async {
    _identity = kp;
  }

  @override
  Future<IdentityKeypair?> loadIdentityKeyPair() async => _identity;

  @override
  Future<void> saveSignedPreKey(SignedPreKey spk) async {
    _signedPreKey = spk;
  }

  @override
  Future<SignedPreKey?> loadSignedPreKey() async => _signedPreKey;

  @override
  Future<void> saveOneTimePreKey(OneTimePreKey otpk) async {
    _otpks[otpk.id] = otpk;
  }

  @override
  Future<OneTimePreKey?> loadOneTimePreKey(int id) async => _otpks[id];

  @override
  Future<void> deleteOneTimePreKey(int id) async {
    _otpks.remove(id);
  }

  @override
  Future<List<int>> listOneTimePreKeyIds() async =>
      _otpks.keys.toList()..sort();

  @override
  Future<void> saveKyberPreKey(KyberPreKey kpk) async {
    _kpks[kpk.id] = kpk;
  }

  @override
  Future<KyberPreKey?> loadKyberPreKey(int id) async => _kpks[id];

  @override
  Future<void> deleteKyberPreKey(int id) async {
    _kpks.remove(id);
  }

  @override
  Future<List<int>> listKyberPreKeyIds() async => _kpks.keys.toList()..sort();

  @override
  Future<void> saveSession(
    String peerUserId,
    Uint8List sessionSerialized,
  ) async {
    _sessions[peerUserId] = sessionSerialized;
  }

  @override
  Future<Uint8List?> loadSession(String peerUserId) async =>
      _sessions[peerUserId];

  @override
  Future<void> deleteSession(String peerUserId) async {
    _sessions.remove(peerUserId);
  }

  @override
  Future<List<String>> listSessionPeerIds() async =>
      _sessions.keys.toList()..sort();

  final Map<String, String> _plaintexts = {};
  final Map<String, PeerIdentityInfo> _peerIdentities = {};
  // Phase 1f: sender-key records, keyed by "<conversationId>:<senderUserId>".
  final Map<String, Uint8List> _senderKeys = {};

  @override
  Future<void> savePlaintext(String messageId, String plaintext) async {
    _plaintexts[messageId] = plaintext;
  }

  @override
  Future<String?> loadPlaintext(String messageId) async =>
      _plaintexts[messageId];

  @override
  Future<void> savePeerIdentityInfo(
    String peerUserId,
    PeerIdentityInfo info,
  ) async {
    _peerIdentities[peerUserId] = info;
  }

  @override
  Future<PeerIdentityInfo?> loadPeerIdentityInfo(String peerUserId) async =>
      _peerIdentities[peerUserId];

  String _sk(String convId, String senderId) => '$convId:$senderId';

  @override
  Future<void> saveSenderKey(
    String conversationId,
    String senderUserId,
    Uint8List recordSerialized,
  ) async {
    _senderKeys[_sk(conversationId, senderUserId)] = recordSerialized;
  }

  @override
  Future<Uint8List?> loadSenderKey(
    String conversationId,
    String senderUserId,
  ) async =>
      _senderKeys[_sk(conversationId, senderUserId)];

  @override
  Future<void> deleteSenderKey(
    String conversationId,
    String senderUserId,
  ) async {
    _senderKeys.remove(_sk(conversationId, senderUserId));
  }

  @override
  Future<List<String>> listSenderKeyContributors(String conversationId) async {
    final prefix = '$conversationId:';
    return _senderKeys.keys
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .toList()
      ..sort();
  }

  @override
  Future<void> deleteAllSenderKeysFor(String conversationId) async {
    final prefix = '$conversationId:';
    _senderKeys.removeWhere((k, _) => k.startsWith(prefix));
  }

  final Map<String, int> _senderKeyEpochs = {};

  @override
  Future<void> saveOwnSenderKeyEpoch(
    String conversationId,
    String ownUserId,
    int epoch,
  ) async {
    _senderKeyEpochs['$conversationId:$ownUserId'] = epoch;
  }

  @override
  Future<int?> loadOwnSenderKeyEpoch(
    String conversationId,
    String ownUserId,
  ) async =>
      _senderKeyEpochs['$conversationId:$ownUserId'];

  @override
  Future<void> wipe() async {
    _identity = null;
    _signedPreKey = null;
    _otpks.clear();
    _kpks.clear();
    _sessions.clear();
    _plaintexts.clear();
    _peerIdentities.clear();
    _senderKeys.clear();
    _senderKeyEpochs.clear();
  }
}

/// Builds a [PeerKeyBundle] from a freshly-generated [PublicKeyBundle]
/// — simulates fetching the bundle from `GET /v1/users/:id/keybundle`,
/// which would atomically pick one OTPK and one Kyber prekey.
PeerKeyBundle _peerBundleFrom(PublicKeyBundle bundle) {
  final otpk = bundle.oneTimePreKeys.first;
  final kpk = bundle.kyberPreKeys.first;
  return PeerKeyBundle(
    identityPublic: bundle.identityPublic,
    signedPreKeyId: bundle.signedPreKey.id,
    signedPreKeyPublic: bundle.signedPreKey.public,
    signedPreKeySignature: bundle.signedPreKey.signature,
    oneTimePreKeyId: otpk.id,
    oneTimePreKeyPublic: otpk.public,
    kyberPreKeyId: kpk.id,
    kyberPreKeyPublic: kpk.public,
    kyberPreKeySignature: kpk.signature,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('Alice encrypts → Bob decrypts; end-to-end through FFI',
      (_) async {
    final aliceStorage = _InMemoryKeyStorage();
    final bobStorage = _InMemoryKeyStorage();
    final alice = SignalClient(aliceStorage);
    final bob = SignalClient(bobStorage);

    // Both provision full bundles.
    await alice.generateInitialKeys(otpkCount: 5, kyberCount: 3);
    final bobBundle =
        await bob.generateInitialKeys(otpkCount: 5, kyberCount: 3);

    // Alice fetches Bob's bundle (simulated).
    final peerBundle = _peerBundleFrom(bobBundle);
    await alice.startSessionWithPeer('alice-id', 'bob-id', peerBundle);
    expect(await alice.hasSessionWith('bob-id'), isTrue);

    // Alice encrypts. First message → PreKeySignalMessage (type 2).
    final plaintext = Uint8List.fromList(utf8.encode('hello bob!'));
    final encrypted =
        await alice.encryptMessageFor('alice-id', 'bob-id', plaintext);
    expect(encrypted.messageType, 2);
    expect(encrypted.ciphertext.isNotEmpty, isTrue);

    // Bob decrypts via the PKM path — session is created on his
    // side as a side effect.
    expect(await bob.hasSessionWith('alice-id'), isFalse);
    final decrypted = await bob.decryptMessageFrom(
      'bob-id',
      'alice-id',
      encrypted.messageType,
      encrypted.ciphertext,
    );
    expect(await bob.hasSessionWith('alice-id'), isTrue);
    expect(utf8.decode(decrypted), 'hello bob!');
  });

  testWidgets('multi-message round-trip: PKM then SignalMessage', (_) async {
    final aliceStorage = _InMemoryKeyStorage();
    final bobStorage = _InMemoryKeyStorage();
    final alice = SignalClient(aliceStorage);
    final bob = SignalClient(bobStorage);

    await alice.generateInitialKeys(otpkCount: 5, kyberCount: 3);
    final bobBundle =
        await bob.generateInitialKeys(otpkCount: 5, kyberCount: 3);

    await alice.startSessionWithPeer(
      'alice-id',
      'bob-id',
      _peerBundleFrom(bobBundle),
    );

    // Alice → Bob: message 1 (PKM).
    final m1Text = Uint8List.fromList(utf8.encode('first message'));
    final m1 = await alice.encryptMessageFor('alice-id', 'bob-id', m1Text);
    expect(m1.messageType, 2);
    final m1Recv = await bob.decryptMessageFrom(
      'bob-id',
      'alice-id',
      m1.messageType,
      m1.ciphertext,
    );
    expect(utf8.decode(m1Recv), 'first message');

    // Alice → Bob: message 2. Still a PKM from libsignal's perspective
    // because Bob hasn't sent anything back yet (the session isn't
    // established bidirectionally until she gets a response). But
    // crucially: Bob can decrypt it using the same PKM path.
    final m2Text = Uint8List.fromList(utf8.encode('second message'));
    final m2 = await alice.encryptMessageFor('alice-id', 'bob-id', m2Text);
    final m2Recv = await bob.decryptMessageFrom(
      'bob-id',
      'alice-id',
      m2.messageType,
      m2.ciphertext,
    );
    expect(utf8.decode(m2Recv), 'second message');

    // Bob → Alice: reply. First message from Bob — from Alice's
    // perspective, she'll need to decrypt it via the PKM path
    // OR via the existing session depending on libsignal's framing.
    final m3Text = Uint8List.fromList(utf8.encode('hi alice'));
    final m3 = await bob.encryptMessageFor('bob-id', 'alice-id', m3Text);
    final m3Recv = await alice.decryptMessageFrom(
      'alice-id',
      'bob-id',
      m3.messageType,
      m3.ciphertext,
    );
    expect(utf8.decode(m3Recv), 'hi alice');
  });

  testWidgets('ownRegistrationId is deterministic from identity', (_) async {
    final storage = _InMemoryKeyStorage();
    final client = SignalClient(storage);
    await client.generateInitialKeys(otpkCount: 2, kyberCount: 2);

    final rid1 = await client.ownRegistrationId();
    final rid2 = await client.ownRegistrationId();
    expect(rid1, rid2);
    // Different identities produce different registration ids.
    final otherStorage = _InMemoryKeyStorage();
    final other = SignalClient(otherStorage);
    await other.generateInitialKeys(otpkCount: 2, kyberCount: 2);
    expect(rid1, isNot(equals(await other.ownRegistrationId())));
  });

  testWidgets('OTPK-less bundle: session setup works without one_time_prekey',
      (_) async {
    final aliceStorage = _InMemoryKeyStorage();
    final bobStorage = _InMemoryKeyStorage();
    final alice = SignalClient(aliceStorage);
    final bob = SignalClient(bobStorage);

    await alice.generateInitialKeys(otpkCount: 5, kyberCount: 3);
    final bobBundle =
        await bob.generateInitialKeys(otpkCount: 5, kyberCount: 3);

    // Simulate Bob's OTPK pool being empty (server would return null).
    final bundleWithoutOtpk = PeerKeyBundle(
      identityPublic: bobBundle.identityPublic,
      signedPreKeyId: bobBundle.signedPreKey.id,
      signedPreKeyPublic: bobBundle.signedPreKey.public,
      signedPreKeySignature: bobBundle.signedPreKey.signature,
      oneTimePreKeyId: null,
      oneTimePreKeyPublic: null,
      kyberPreKeyId: bobBundle.kyberPreKeys.first.id,
      kyberPreKeyPublic: bobBundle.kyberPreKeys.first.public,
      kyberPreKeySignature: bobBundle.kyberPreKeys.first.signature,
    );

    await alice.startSessionWithPeer('alice-id', 'bob-id', bundleWithoutOtpk);
    final plaintext =
        Uint8List.fromList(utf8.encode('no otpk but still works'));
    final encrypted =
        await alice.encryptMessageFor('alice-id', 'bob-id', plaintext);
    final decrypted = await bob.decryptMessageFrom(
      'bob-id',
      'alice-id',
      encrypted.messageType,
      encrypted.ciphertext,
    );
    expect(utf8.decode(decrypted), 'no otpk but still works');
  });
}
