// Secure storage for Signal Protocol keys, backed by iOS Keychain
// and Android Keystore via flutter_secure_storage. Keys are namespaced
// with an `e2ee:` prefix so sign-out can wipe them without touching
// other secure-storage entries the app uses.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../src/rust/api/identity.dart';
import '../../src/rust/api/prekeys.dart';

/// Per-peer identity pinning record. Null timestamps indicate the
/// user has never seen an identity change for this peer (first-
/// session TOFU) or has already acknowledged the last change.
class PeerIdentityInfo {
  /// The peer's identity public key (33-byte libsignal encoding)
  /// as of the most recent session setup.
  final Uint8List identityPublic;

  /// When the stored identity changed — null if it hasn't.
  final DateTime? changedAt;

  /// When the user last dismissed the "identity changed" banner.
  /// The banner is visible iff changedAt != null &&
  /// (dismissedAt == null || changedAt > dismissedAt).
  final DateTime? dismissedAt;

  const PeerIdentityInfo({
    required this.identityPublic,
    this.changedAt,
    this.dismissedAt,
  });

  /// True iff the UI should be showing the "security code changed" banner.
  bool get showChangeBanner =>
      changedAt != null &&
      (dismissedAt == null || changedAt!.isAfter(dismissedAt!));

  PeerIdentityInfo copyWith({
    Uint8List? identityPublic,
    DateTime? changedAt,
    DateTime? dismissedAt,
  }) {
    return PeerIdentityInfo(
      identityPublic: identityPublic ?? this.identityPublic,
      changedAt: changedAt ?? this.changedAt,
      dismissedAt: dismissedAt ?? this.dismissedAt,
    );
  }
}

/// Storage key prefix for all E2EE material. Used as a filter when
/// wiping on sign-out so we don't nuke unrelated secure entries.
const _prefix = 'e2ee:';

const _identityKey = '${_prefix}identity';
const _signedPreKey = '${_prefix}spk';
const _otpkPrefix = '${_prefix}otpk:';
const _kpkPrefix = '${_prefix}kpk:';
const _sessionPrefix = '${_prefix}session:';
const _plaintextPrefix = '${_prefix}plaintext:';
const _peerIdentityPrefix = '${_prefix}peer_identity:';
// Phase 1f: Sender-key records for group E2EE. Keyed by
// `<conversationId>:<senderUserId>` so listing all contributors to a
// group is a simple prefix scan. Conversation ids are UUIDs so the
// `:` separator is unambiguous.
const _senderKeyPrefix = '${_prefix}senderkey:';
// Phase 1f: epoch of the currently-stored sender-key record for
// `(conversationId, ownUserId)`. Compared against the conversation's
// `epoch` on send — when the conversation has advanced past the
// stored value (membership change), we drop the record and generate
// a fresh chain, which redistributes SKDMs to the new member set.
// Kept separate from the record itself so we don't re-serialize
// libsignal's ~KB sender-key blob just to annotate an integer.
const _senderKeyEpochPrefix = '${_prefix}senderkey_epoch:';

/// Serializes a [Uint8List] for storage. Base64 is compact enough and
/// lets us keep the whole value type JSON-friendly so [jsonEncode] /
/// [jsonDecode] can round-trip composite structs.
String _encodeBytes(List<int> bytes) => base64.encode(bytes);

Uint8List _decodeBytes(String s) => base64.decode(s);

/// Abstract interface so tests can substitute an in-memory store.
/// Production wires [SecureKeyStorage]; unit tests can swap a fake.
abstract class KeyStorage {
  Future<void> saveIdentityKeyPair(IdentityKeypair kp);
  Future<IdentityKeypair?> loadIdentityKeyPair();

  Future<void> saveSignedPreKey(SignedPreKey spk);
  Future<SignedPreKey?> loadSignedPreKey();

  Future<void> saveOneTimePreKey(OneTimePreKey otpk);
  Future<OneTimePreKey?> loadOneTimePreKey(int id);
  Future<void> deleteOneTimePreKey(int id);
  Future<List<int>> listOneTimePreKeyIds();

  // Kyber prekeys (post-quantum). Same consumption semantics as OTPKs.
  Future<void> saveKyberPreKey(KyberPreKey kpk);
  Future<KyberPreKey?> loadKyberPreKey(int id);
  Future<void> deleteKyberPreKey(int id);
  Future<List<int>> listKyberPreKeyIds();

  // Per-peer Double Ratchet session records. Keyed by peer user id.
  // Record value is the protobuf-serialized SessionRecord bytes that
  // libsignal's session API hands us back after each encrypt/decrypt.
  Future<void> saveSession(String peerUserId, Uint8List sessionSerialized);
  Future<Uint8List?> loadSession(String peerUserId);
  Future<void> deleteSession(String peerUserId);
  Future<List<String>> listSessionPeerIds();

  // TOFU identity pinning per peer. We remember each peer's identity
  // public key the first time we build a session with them, and
  // detect changes on subsequent handshakes (peer reinstalled,
  // switched devices, or is being MITM'd). A change records a
  // `changed_at` timestamp that the UI uses to show a banner;
  // `dismissed_at` lets the user acknowledge so the banner goes
  // away without clearing the history.
  Future<void> savePeerIdentityInfo(String peerUserId, PeerIdentityInfo info);
  Future<PeerIdentityInfo?> loadPeerIdentityInfo(String peerUserId);

  // Phase 1f: Per-sender sender-key records for group E2EE. Keyed
  // by (conversation_id, sender_user_id). A group stores records
  // for every active sender that's distributed an SKDM to us, plus
  // our own outgoing chain. Mirrors libsignal's
  // InMemSenderKeyStore, which keys by (ProtocolAddress,
  // distribution_id). We reuse the conversation UUID as the
  // distribution_id on both ends.
  Future<void> saveSenderKey(
    String conversationId,
    String senderUserId,
    Uint8List recordSerialized,
  );
  Future<Uint8List?> loadSenderKey(
    String conversationId,
    String senderUserId,
  );
  Future<void> deleteSenderKey(String conversationId, String senderUserId);

  /// All sender user ids with a stored record in this group,
  /// including our own user id once we've sent at least once.
  Future<List<String>> listSenderKeyContributors(String conversationId);

  /// Wipe every sender-key record for a conversation. Called on
  /// sender-key rotation (membership change) so all previously
  /// distributed chains are forgotten.
  Future<void> deleteAllSenderKeysFor(String conversationId);

  /// Phase 1f: persist + read the epoch that our own sender-key
  /// chain was generated under. Used to detect when the conversation
  /// has advanced past us (add/remove member) and we need to rotate.
  Future<void> saveOwnSenderKeyEpoch(
    String conversationId,
    String ownUserId,
    int epoch,
  );
  Future<int?> loadOwnSenderKeyEpoch(
    String conversationId,
    String ownUserId,
  );

  // Plaintext cache keyed by server message id. Written:
  //   - on send (we stash our own outgoing plaintext — Double Ratchet
  //     is one-way so we can't decrypt our own ciphertext later)
  //   - on successful decrypt of an incoming message (so re-fetches
  //     don't re-run the ratchet; that would advance state past the
  //     server's view and break subsequent decrypts)
  // Signal's clients do this — their local message store IS the
  // source of truth for plaintext; server holds only ciphertext.
  Future<void> savePlaintext(String messageId, String plaintext);
  Future<String?> loadPlaintext(String messageId);

  /// Remove every `e2ee:`-prefixed entry. Called on sign-out.
  Future<void> wipe();
}

/// Production implementation backed by flutter_secure_storage.
/// Reads and writes to iOS Keychain / Android EncryptedSharedPreferences
/// depending on platform.
class SecureKeyStorage implements KeyStorage {
  final FlutterSecureStorage _storage;

  SecureKeyStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // flutter_secure_storage 10 deprecated the
              // `encryptedSharedPreferences` flag because Google
              // deprecated the underlying Jetpack Security library.
              // The package now uses custom AES-GCM ciphers under
              // hardware-backed Keystore by default and migrates
              // existing encryptedSharedPreferences data on first
              // access. Cipher selection is no longer something
              // we configure here.
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  @override
  Future<void> saveIdentityKeyPair(IdentityKeypair kp) async {
    final json = jsonEncode({
      'serialized': _encodeBytes(kp.serialized),
      'public_key': _encodeBytes(kp.publicKey),
    });
    await _storage.write(key: _identityKey, value: json);
  }

  @override
  Future<IdentityKeypair?> loadIdentityKeyPair() async {
    final raw = await _storage.read(key: _identityKey);
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return IdentityKeypair(
      serialized: _decodeBytes(m['serialized'] as String),
      publicKey: _decodeBytes(m['public_key'] as String),
    );
  }

  @override
  Future<void> saveSignedPreKey(SignedPreKey spk) async {
    final json = jsonEncode({
      'id': spk.id,
      'serialized': _encodeBytes(spk.serialized),
      'public_key': _encodeBytes(spk.publicKey),
      'signature': _encodeBytes(spk.signature),
    });
    await _storage.write(key: _signedPreKey, value: json);
  }

  @override
  Future<SignedPreKey?> loadSignedPreKey() async {
    final raw = await _storage.read(key: _signedPreKey);
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return SignedPreKey(
      id: m['id'] as int,
      serialized: _decodeBytes(m['serialized'] as String),
      publicKey: _decodeBytes(m['public_key'] as String),
      signature: _decodeBytes(m['signature'] as String),
    );
  }

  @override
  Future<void> saveOneTimePreKey(OneTimePreKey otpk) async {
    final json = jsonEncode({
      'id': otpk.id,
      'serialized': _encodeBytes(otpk.serialized),
      'public_key': _encodeBytes(otpk.publicKey),
    });
    await _storage.write(key: '$_otpkPrefix${otpk.id}', value: json);
  }

  @override
  Future<OneTimePreKey?> loadOneTimePreKey(int id) async {
    final raw = await _storage.read(key: '$_otpkPrefix$id');
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return OneTimePreKey(
      id: m['id'] as int,
      serialized: _decodeBytes(m['serialized'] as String),
      publicKey: _decodeBytes(m['public_key'] as String),
    );
  }

  @override
  Future<void> deleteOneTimePreKey(int id) async {
    await _storage.delete(key: '$_otpkPrefix$id');
  }

  @override
  Future<List<int>> listOneTimePreKeyIds() async {
    final all = await _storage.readAll();
    final ids = <int>[];
    for (final k in all.keys) {
      if (k.startsWith(_otpkPrefix)) {
        final suffix = k.substring(_otpkPrefix.length);
        final id = int.tryParse(suffix);
        if (id != null) ids.add(id);
      }
    }
    ids.sort();
    return ids;
  }

  @override
  Future<void> saveKyberPreKey(KyberPreKey kpk) async {
    final json = jsonEncode({
      'id': kpk.id,
      'serialized': _encodeBytes(kpk.serialized),
      'public_key': _encodeBytes(kpk.publicKey),
      'signature': _encodeBytes(kpk.signature),
    });
    await _storage.write(key: '$_kpkPrefix${kpk.id}', value: json);
  }

  @override
  Future<KyberPreKey?> loadKyberPreKey(int id) async {
    final raw = await _storage.read(key: '$_kpkPrefix$id');
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return KyberPreKey(
      id: m['id'] as int,
      serialized: _decodeBytes(m['serialized'] as String),
      publicKey: _decodeBytes(m['public_key'] as String),
      signature: _decodeBytes(m['signature'] as String),
    );
  }

  @override
  Future<void> deleteKyberPreKey(int id) async {
    await _storage.delete(key: '$_kpkPrefix$id');
  }

  @override
  Future<List<int>> listKyberPreKeyIds() async {
    final all = await _storage.readAll();
    final ids = <int>[];
    for (final k in all.keys) {
      if (k.startsWith(_kpkPrefix)) {
        final suffix = k.substring(_kpkPrefix.length);
        final id = int.tryParse(suffix);
        if (id != null) ids.add(id);
      }
    }
    ids.sort();
    return ids;
  }

  @override
  Future<void> saveSession(
    String peerUserId,
    Uint8List sessionSerialized,
  ) async {
    await _storage.write(
      key: '$_sessionPrefix$peerUserId',
      value: _encodeBytes(sessionSerialized),
    );
  }

  @override
  Future<Uint8List?> loadSession(String peerUserId) async {
    final raw = await _storage.read(key: '$_sessionPrefix$peerUserId');
    if (raw == null) return null;
    return _decodeBytes(raw);
  }

  @override
  Future<void> deleteSession(String peerUserId) async {
    await _storage.delete(key: '$_sessionPrefix$peerUserId');
  }

  @override
  Future<List<String>> listSessionPeerIds() async {
    final all = await _storage.readAll();
    final peers = <String>[];
    for (final k in all.keys) {
      if (k.startsWith(_sessionPrefix)) {
        peers.add(k.substring(_sessionPrefix.length));
      }
    }
    peers.sort();
    return peers;
  }

  @override
  Future<void> savePeerIdentityInfo(
    String peerUserId,
    PeerIdentityInfo info,
  ) async {
    final json = jsonEncode({
      'identity_public': _encodeBytes(info.identityPublic),
      if (info.changedAt != null)
        'changed_at': info.changedAt!.toIso8601String(),
      if (info.dismissedAt != null)
        'dismissed_at': info.dismissedAt!.toIso8601String(),
    });
    await _storage.write(
      key: '$_peerIdentityPrefix$peerUserId',
      value: json,
    );
  }

  @override
  Future<PeerIdentityInfo?> loadPeerIdentityInfo(String peerUserId) async {
    final raw = await _storage.read(key: '$_peerIdentityPrefix$peerUserId');
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return PeerIdentityInfo(
      identityPublic: _decodeBytes(m['identity_public'] as String),
      changedAt: m['changed_at'] != null
          ? DateTime.parse(m['changed_at'] as String)
          : null,
      dismissedAt: m['dismissed_at'] != null
          ? DateTime.parse(m['dismissed_at'] as String)
          : null,
    );
  }

  String _senderKeyStorageKey(String conversationId, String senderUserId) =>
      '$_senderKeyPrefix$conversationId:$senderUserId';

  @override
  Future<void> saveSenderKey(
    String conversationId,
    String senderUserId,
    Uint8List recordSerialized,
  ) async {
    await _storage.write(
      key: _senderKeyStorageKey(conversationId, senderUserId),
      value: _encodeBytes(recordSerialized),
    );
  }

  @override
  Future<Uint8List?> loadSenderKey(
    String conversationId,
    String senderUserId,
  ) async {
    final raw = await _storage.read(
        key: _senderKeyStorageKey(conversationId, senderUserId));
    if (raw == null) return null;
    return _decodeBytes(raw);
  }

  @override
  Future<void> deleteSenderKey(
    String conversationId,
    String senderUserId,
  ) async {
    await _storage.delete(
        key: _senderKeyStorageKey(conversationId, senderUserId));
  }

  @override
  Future<List<String>> listSenderKeyContributors(String conversationId) async {
    final all = await _storage.readAll();
    final prefix = '$_senderKeyPrefix$conversationId:';
    final ids = <String>[];
    for (final k in all.keys) {
      if (k.startsWith(prefix)) {
        ids.add(k.substring(prefix.length));
      }
    }
    ids.sort();
    return ids;
  }

  @override
  Future<void> deleteAllSenderKeysFor(String conversationId) async {
    final all = await _storage.readAll();
    final prefix = '$_senderKeyPrefix$conversationId:';
    for (final k in all.keys) {
      if (k.startsWith(prefix)) {
        await _storage.delete(key: k);
      }
    }
  }

  String _senderKeyEpochStorageKey(String conversationId, String ownUserId) =>
      '$_senderKeyEpochPrefix$conversationId:$ownUserId';

  @override
  Future<void> saveOwnSenderKeyEpoch(
    String conversationId,
    String ownUserId,
    int epoch,
  ) async {
    await _storage.write(
      key: _senderKeyEpochStorageKey(conversationId, ownUserId),
      value: epoch.toString(),
    );
  }

  @override
  Future<int?> loadOwnSenderKeyEpoch(
    String conversationId,
    String ownUserId,
  ) async {
    final raw = await _storage.read(
        key: _senderKeyEpochStorageKey(conversationId, ownUserId));
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  @override
  Future<void> savePlaintext(String messageId, String plaintext) async {
    await _storage.write(
      key: '$_plaintextPrefix$messageId',
      value: plaintext,
    );
  }

  @override
  Future<String?> loadPlaintext(String messageId) async {
    return _storage.read(key: '$_plaintextPrefix$messageId');
  }

  @override
  Future<void> wipe() async {
    final all = await _storage.readAll();
    for (final k in all.keys) {
      if (k.startsWith(_prefix)) {
        await _storage.delete(key: k);
      }
    }
  }
}
