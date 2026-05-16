// High-level Signal Protocol client state.
//
// Owns the user's identity key and prekey inventory on this device.
// First-run generates a full set; rotation/replenishment keep them
// fresh. Private keys live in [KeyStorage] (Keychain / Keystore).
// Public halves are returned as a [PublicKeyBundle] for upload to
// the server key registry (Phase 1c wires the actual endpoint).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../src/rust/api/identity.dart';
import '../../src/rust/api/prekeys.dart';
import '../../src/rust/api/session_1to1.dart';
import '../../src/rust/api/session_group.dart';
import '../../src/rust/frb_generated.dart';
import 'key_storage.dart';

/// Public halves only — safe to ship over the wire. The server stores
/// this per-device; peers fetch it before initiating an E2EE session.
class PublicKeyBundle {
  final Uint8List identityPublic;
  final PublicSignedPreKey signedPreKey;
  final List<PublicOneTimePreKey> oneTimePreKeys;
  final List<PublicKyberPreKey> kyberPreKeys;

  const PublicKeyBundle({
    required this.identityPublic,
    required this.signedPreKey,
    required this.oneTimePreKeys,
    required this.kyberPreKeys,
  });

  /// Wire format matches the server's expected `POST /v1/devices/keys/
  /// upload` body (snake_case, base64-encoded bytes).
  Map<String, dynamic> toJson() => {
        'identity_key_pub': base64.encode(identityPublic),
        'signed_prekey': signedPreKey.toJson(),
        'one_time_prekeys':
            oneTimePreKeys.map((e) => e.toJson()).toList(growable: false),
        'kyber_prekeys':
            kyberPreKeys.map((e) => e.toJson()).toList(growable: false),
      };
}

class PublicSignedPreKey {
  final int id;
  final Uint8List public;
  final Uint8List signature;

  const PublicSignedPreKey({
    required this.id,
    required this.public,
    required this.signature,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'public': base64.encode(public),
        'signature': base64.encode(signature),
      };
}

class PublicOneTimePreKey {
  final int id;
  final Uint8List public;

  const PublicOneTimePreKey({required this.id, required this.public});

  Map<String, dynamic> toJson() => {
        'id': id,
        'public': base64.encode(public),
      };
}

/// A peer's key bundle as returned by `GET /v1/users/:id/keybundle`.
/// Used as input to [SignalClient.startSessionWithPeer].
class PeerKeyBundle {
  final Uint8List identityPublic;
  final int signedPreKeyId;
  final Uint8List signedPreKeyPublic;
  final Uint8List signedPreKeySignature;
  final int? oneTimePreKeyId; // may be null when server pool is empty
  final Uint8List? oneTimePreKeyPublic;
  final int kyberPreKeyId;
  final Uint8List kyberPreKeyPublic;
  final Uint8List kyberPreKeySignature;

  const PeerKeyBundle({
    required this.identityPublic,
    required this.signedPreKeyId,
    required this.signedPreKeyPublic,
    required this.signedPreKeySignature,
    required this.oneTimePreKeyId,
    required this.oneTimePreKeyPublic,
    required this.kyberPreKeyId,
    required this.kyberPreKeyPublic,
    required this.kyberPreKeySignature,
  });

  /// Decodes the JSON shape returned by `/v1/users/:id/keybundle`
  /// into the typed struct the FFI wants.
  factory PeerKeyBundle.fromServerJson(Map<String, dynamic> json) {
    final spk = json['signed_prekey'] as Map<String, dynamic>;
    final kpk = json['kyber_prekey'] as Map<String, dynamic>;
    final otpk = json['one_time_prekey'] as Map<String, dynamic>?;
    return PeerKeyBundle(
      identityPublic: base64.decode(json['identity_key_pub'] as String),
      signedPreKeyId: spk['id'] as int,
      signedPreKeyPublic: base64.decode(spk['public'] as String),
      signedPreKeySignature: base64.decode(spk['signature'] as String),
      oneTimePreKeyId: otpk?['id'] as int?,
      oneTimePreKeyPublic:
          otpk == null ? null : base64.decode(otpk['public'] as String),
      kyberPreKeyId: kpk['id'] as int,
      kyberPreKeyPublic: base64.decode(kpk['public'] as String),
      kyberPreKeySignature: base64.decode(kpk['signature'] as String),
    );
  }
}

/// Result of [SignalClient.encryptMessage]. The `messageType` is
/// libsignal's CiphertextMessageType tag:
///   2 = PreKeySignalMessage (first message in a session; recipient
///       must decrypt via the "prekey" path)
///   3 = SignalMessage (subsequent messages on an established session)
/// Clients should stamp this on the wire so the recipient knows
/// which decrypt path to use.
class EncryptedMessage {
  final int messageType;
  final Uint8List ciphertext;

  const EncryptedMessage({required this.messageType, required this.ciphertext});
}

/// Result of [SignalClient.startSessionWithPeer]. Callers use these
/// flags for security counters — e.g. recording when a peer's
/// long-term identity key has rolled
/// between sessions (reinstalled, new device, or — worst case — a
/// server-mediated MITM).
class StartSessionOutcome {
  /// True iff we had a peer identity on file and the new bundle's
  /// identity public key differs from it. Triggers the TOFU banner
  /// (already handled by SignalClient internally) AND is worth
  /// reporting as a counter so we can spot patterns.
  final bool identityChanged;

  /// True iff this is the first time we've established a session
  /// with this peer (no prior identity stored). Separate from
  /// `identityChanged` so telemetry can distinguish "user just
  /// started a new conversation" from "existing conversation,
  /// peer's key rolled".
  final bool firstContact;

  const StartSessionOutcome({
    required this.identityChanged,
    required this.firstContact,
  });
}

/// A Kyber prekey's public half + signature. The signature is the
/// identity's Ed25519 signature over the Kyber public-key bytes, so
/// recipients can verify bundle authenticity before using it in X3DH.
class PublicKyberPreKey {
  final int id;
  final Uint8List public;
  final Uint8List signature;

  const PublicKyberPreKey({
    required this.id,
    required this.public,
    required this.signature,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'public': base64.encode(public),
        'signature': base64.encode(signature),
      };
}

/// Top-level orchestrator for client-side key lifecycle.
///
/// Typical usage:
/// ```dart
/// final client = SignalClient(storage);
/// await client.initialize();
/// if (!(await client.hasKeys())) {
///   final bundle = await client.generateInitialKeys();
///   await api.uploadKeys(bundle);  // Phase 1c
/// }
/// // Weekly:
/// await client.rotateSignedPreKey();
/// // On app resume, if low:
/// await client.replenishOneTimePreKeys();
/// ```
class SignalClient {
  final KeyStorage _storage;
  bool _ffiReady = false;

  SignalClient(this._storage);

  /// Default batch size for OTPK generation. Signal's reference spec
  /// uses 100 — enough to establish sessions with ~100 new peers
  /// before a replenishment round-trip is needed.
  static const defaultOtpkBatch = 100;

  /// Below this remaining count, [replenishOneTimePreKeys] will top
  /// up. Chosen so a user can set up sessions with a reasonable burst
  /// of peers between refreshes.
  static const defaultOtpkThreshold = 20;

  /// Default batch size for Kyber prekey generation. Smaller than
  /// classical OTPKs because Kyber records are ~3KB each (vs ~70
  /// bytes for X25519 OTPKs). 20 is enough to set up PQC-hybrid
  /// sessions with ~20 new peers before replenishment.
  static const defaultKyberBatch = 20;

  /// Threshold for Kyber replenishment.
  static const defaultKyberThreshold = 5;

  /// Loads the Rust dynamic library. Idempotent — flutter_rust_bridge
  /// 2.x throws if `RustLib.init()` is called twice, so we catch that
  /// specific error and treat it as "already loaded by someone else"
  /// (the app bootstrap, another SignalClient, a test setUp).
  Future<void> initialize() async {
    if (_ffiReady) return;
    try {
      await RustLib.init();
    } on StateError catch (e) {
      if (!e.message.contains('twice')) rethrow;
    }
    _ffiReady = true;
  }

  /// True iff an identity keypair is already persisted. Fast enough
  /// to call on every app start.
  Future<bool> hasKeys() async {
    final id = await _storage.loadIdentityKeyPair();
    return id != null;
  }

  /// First-run setup: generates identity + signed prekey + OTPK batch
  /// + Kyber prekey batch and persists them all. Returns the public
  /// halves as a [PublicKeyBundle] for immediate server upload.
  ///
  /// Throws [StateError] if keys already exist (caller should check
  /// [hasKeys] first, or call [wipeKeys] to start fresh).
  Future<PublicKeyBundle> generateInitialKeys({
    int otpkCount = defaultOtpkBatch,
    int kyberCount = defaultKyberBatch,
  }) async {
    await initialize();
    if (await hasKeys()) {
      throw StateError(
        'keys already exist on this device; call wipeKeys() to reset',
      );
    }

    // 1. Identity. One keypair per device, never rotated (rotation
    // means a new device == new identity key).
    final identity = generateIdentityKeypair();
    await _storage.saveIdentityKeyPair(identity);

    // 2. Signed prekey. IDs start at 1 and monotonically increase.
    // Rotation bumps to current+1, so the server can distinguish
    // generations for debugging / anomaly detection.
    const initialSpkId = 1;
    final spk = generateSignedPrekey(
      identitySerialized: identity.serialized,
      keyId: initialSpkId,
    );
    await _storage.saveSignedPreKey(spk);

    // 3. One-time prekeys. Batch generated and persisted individually.
    final otpks = generatePrekeyBatch(startId: 1, count: otpkCount);
    for (final otpk in otpks) {
      await _storage.saveOneTimePreKey(otpk);
    }

    // 4. Kyber prekeys (PQC). Same consumption semantics as OTPKs.
    final kpks = generateKyberPrekeyBatch(
      identitySerialized: identity.serialized,
      startId: 1,
      count: kyberCount,
    );
    for (final kpk in kpks) {
      await _storage.saveKyberPreKey(kpk);
    }

    return _buildPublicBundle(
      identity: identity,
      spk: spk,
      otpks: otpks,
      kpks: kpks,
    );
  }

  /// Rebuilds the public bundle from whatever is in storage — useful
  /// for re-uploading after a server-side reset. Does not generate
  /// any fresh material.
  Future<PublicKeyBundle?> currentPublicBundle() async {
    await initialize();
    final identity = await _storage.loadIdentityKeyPair();
    final spk = await _storage.loadSignedPreKey();
    if (identity == null || spk == null) return null;

    final otpkIds = await _storage.listOneTimePreKeyIds();
    final otpks = <OneTimePreKey>[];
    for (final id in otpkIds) {
      final otpk = await _storage.loadOneTimePreKey(id);
      if (otpk != null) otpks.add(otpk);
    }

    final kpkIds = await _storage.listKyberPreKeyIds();
    final kpks = <KyberPreKey>[];
    for (final id in kpkIds) {
      final kpk = await _storage.loadKyberPreKey(id);
      if (kpk != null) kpks.add(kpk);
    }

    return _buildPublicBundle(
      identity: identity,
      spk: spk,
      otpks: otpks,
      kpks: kpks,
    );
  }

  /// Generates a fresh signed prekey, bumping the id past the previous
  /// generation. Persists and returns the public half for upload.
  /// Called weekly by a background task (Phase 2 wires the scheduler).
  Future<PublicSignedPreKey> rotateSignedPreKey() async {
    await initialize();
    final identity = await _storage.loadIdentityKeyPair();
    if (identity == null) {
      throw StateError(
        'no identity key; call generateInitialKeys() first',
      );
    }
    final current = await _storage.loadSignedPreKey();
    final nextId = (current?.id ?? 0) + 1;

    final spk = generateSignedPrekey(
      identitySerialized: identity.serialized,
      keyId: nextId,
    );
    await _storage.saveSignedPreKey(spk);

    return PublicSignedPreKey(
      id: spk.id,
      public: spk.publicKey,
      signature: spk.signature,
    );
  }

  /// Tops up the OTPK inventory when the remaining count drops below
  /// [threshold]. Returns the newly generated public halves for
  /// upload; returns an empty list if the inventory is already above
  /// threshold. Safe to call on every foreground — cheap no-op when
  /// not needed.
  Future<List<PublicOneTimePreKey>> replenishOneTimePreKeys({
    int threshold = defaultOtpkThreshold,
    int batchSize = defaultOtpkBatch,
  }) async {
    await initialize();
    final existingIds = await _storage.listOneTimePreKeyIds();
    if (existingIds.length >= threshold) return const [];

    final maxId = existingIds.isEmpty ? 0 : existingIds.reduce(math.max);
    final newOtpks = generatePrekeyBatch(
      startId: maxId + 1,
      count: batchSize,
    );
    for (final otpk in newOtpks) {
      await _storage.saveOneTimePreKey(otpk);
    }

    return newOtpks
        .map((o) => PublicOneTimePreKey(id: o.id, public: o.publicKey))
        .toList(growable: false);
  }

  /// Called when the server consumed an OTPK for a peer's X3DH setup.
  /// Removes it locally so we don't try to use it again. (Phase 1e
  /// will call this after the first message is decrypted.)
  Future<void> consumeOneTimePreKey(int id) async {
    await _storage.deleteOneTimePreKey(id);
  }

  /// Tops up the Kyber prekey inventory. Mirrors the OTPK version —
  /// generate up to [batchSize] fresh keys when the unconsumed
  /// count falls below [threshold], persist locally, return the
  /// public halves for server upload.
  Future<List<PublicKyberPreKey>> replenishKyberPreKeys({
    int threshold = defaultKyberThreshold,
    int batchSize = defaultKyberBatch,
  }) async {
    await initialize();
    final existingIds = await _storage.listKyberPreKeyIds();
    if (existingIds.length >= threshold) return const [];

    final identity = await _storage.loadIdentityKeyPair();
    if (identity == null) {
      throw StateError(
        'no identity key; call generateInitialKeys() first',
      );
    }
    final maxId = existingIds.isEmpty ? 0 : existingIds.reduce(math.max);
    final fresh = generateKyberPrekeyBatch(
      identitySerialized: identity.serialized,
      startId: maxId + 1,
      count: batchSize,
    );
    for (final kpk in fresh) {
      await _storage.saveKyberPreKey(kpk);
    }

    return fresh
        .map((k) => PublicKyberPreKey(
              id: k.id,
              public: k.publicKey,
              signature: k.signature,
            ))
        .toList(growable: false);
  }

  /// Removes a consumed Kyber prekey by id.
  Future<void> consumeKyberPreKey(int id) async {
    await _storage.deleteKyberPreKey(id);
  }

  /// Wipes all E2EE material on sign-out. Next sign-in generates a
  /// fresh identity — which is equivalent to "this is a new device"
  /// from the Signal Protocol's perspective.
  Future<void> wipeKeys() async {
    await _storage.wipe();
  }

  // ── Phase 1e: 1:1 sessions ──────────────────────────────────
  //
  // Session records are persisted per-peer (keyed by peer user_id).
  // Every encrypt or decrypt loads the current record, calls the
  // Rust FFI, and saves the updated state back. libsignal's Double
  // Ratchet bumps state on every message, so this must stay tight.

  /// True iff we have an established Double Ratchet session with
  /// this peer. When false, callers should fetch the peer's bundle
  /// from `/keybundle` and call [startSessionWithPeer] first.
  Future<bool> hasSessionWith(String peerUserId) async {
    await initialize();
    final s = await _storage.loadSession(peerUserId);
    return s != null;
  }

  /// Derives our registration id from the stored identity public key.
  /// Deterministic — same algorithm in Rust — so peers can compute
  /// each other's registration id from identity_key_pub without it
  /// being on the wire.
  Future<int> ownRegistrationId() async {
    final identity = await _storage.loadIdentityKeyPair();
    if (identity == null) {
      throw StateError('no identity key; call generateInitialKeys() first');
    }
    return deriveRegistrationId(identityPublicKey: identity.publicKey);
  }

  /// Alice-side session setup: takes a peer's bundle (as returned by
  /// `GET /v1/users/:id/keybundle`), builds a Double Ratchet session
  /// via X3DH, and persists it. After this returns, the caller can
  /// [encryptMessageFor] this peer.
  ///
  /// Returns a [StartSessionOutcome] describing whether this was a
  /// first contact or whether the peer's identity key had changed
  /// since we last talked — callers use it for telemetry. (Identity-
  /// change UI banner is already handled internally here via the
  /// stored `PeerIdentityInfo.changedAt` timestamp.)
  Future<StartSessionOutcome> startSessionWithPeer(
    String ownUserId,
    String peerUserId,
    PeerKeyBundle bundle,
  ) async {
    await initialize();
    final identity = await _storage.loadIdentityKeyPair();
    if (identity == null) {
      throw StateError('no identity key; call generateInitialKeys() first');
    }

    final ownRegId = deriveRegistrationId(
      identityPublicKey: identity.publicKey,
    );
    final peerRegId = deriveRegistrationId(
      identityPublicKey: bundle.identityPublic,
    );

    final sessionBytes = initiate1To1Session(
      ownUserId: ownUserId,
      remoteUserId: peerUserId,
      ownIdentitySerialized: identity.serialized,
      ownRegistrationId: ownRegId,
      peerRegistrationId: peerRegId,
      peerIdentityPub: bundle.identityPublic,
      peerSignedPrekeyId: bundle.signedPreKeyId,
      peerSignedPrekeyPub: bundle.signedPreKeyPublic,
      peerSignedPrekeySig: bundle.signedPreKeySignature,
      peerOneTimePrekeyId: bundle.oneTimePreKeyId,
      peerOneTimePrekeyPub: bundle.oneTimePreKeyPublic,
      peerKyberPrekeyId: bundle.kyberPreKeyId,
      peerKyberPrekeyPub: bundle.kyberPreKeyPublic,
      peerKyberPrekeySig: bundle.kyberPreKeySignature,
    );
    await _storage.saveSession(peerUserId, sessionBytes);

    // TOFU identity pinning — compare bundle identity vs what we had
    // on file. First time: record it silently. Later change: stamp
    // changed_at so the UI can raise a banner. We don't gate the
    // session setup on this; Signal's practice is to complete the
    // session + alert the user so they can decide.
    final prior = await _storage.loadPeerIdentityInfo(peerUserId);
    bool identityChanged = false;
    final firstContact = prior == null;
    if (prior == null) {
      await _storage.savePeerIdentityInfo(
        peerUserId,
        PeerIdentityInfo(identityPublic: bundle.identityPublic),
      );
    } else if (!_bytesEqual(prior.identityPublic, bundle.identityPublic)) {
      identityChanged = true;
      await _storage.savePeerIdentityInfo(
        peerUserId,
        prior.copyWith(
          identityPublic: bundle.identityPublic,
          changedAt: DateTime.now(),
          // Leave dismissedAt unchanged so a fresh change raises the
          // banner even if the user dismissed a previous one.
        ),
      );
    }
    return StartSessionOutcome(
      identityChanged: identityChanged,
      firstContact: firstContact,
    );
  }

  /// Marks the peer's most recent identity change as acknowledged so
  /// the UI banner hides until the next change.
  Future<void> dismissIdentityChange(String peerUserId) async {
    final prior = await _storage.loadPeerIdentityInfo(peerUserId);
    if (prior == null) return;
    await _storage.savePeerIdentityInfo(
      peerUserId,
      prior.copyWith(dismissedAt: DateTime.now()),
    );
  }

  /// Convenience for the UI: is there an unacknowledged identity
  /// change for this peer?
  Future<PeerIdentityInfo?> peerIdentityInfo(String peerUserId) async {
    return _storage.loadPeerIdentityInfo(peerUserId);
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Encrypts `plaintext` for [peerUserId] using the stored session.
  /// Throws [StateError] if no session exists — caller should
  /// [startSessionWithPeer] first.
  ///
  /// The session record is updated (Double Ratchet advances on every
  /// message) and persisted before returning.
  Future<EncryptedMessage> encryptMessageFor(
    String ownUserId,
    String peerUserId,
    Uint8List plaintext,
  ) async {
    await initialize();
    final identity = await _storage.loadIdentityKeyPair();
    if (identity == null) {
      throw StateError('no identity key; call generateInitialKeys() first');
    }
    final session = await _storage.loadSession(peerUserId);
    if (session == null) {
      throw StateError(
        'no session with $peerUserId; call startSessionWithPeer() first',
      );
    }
    final regId = deriveRegistrationId(identityPublicKey: identity.publicKey);

    final result = encrypt1To1(
      ownUserId: ownUserId,
      remoteUserId: peerUserId,
      ownIdentitySerialized: identity.serialized,
      ownRegistrationId: regId,
      sessionSerialized: session,
      plaintext: plaintext,
    );
    await _storage.saveSession(peerUserId, result.updatedSessionSerialized);
    return EncryptedMessage(
      messageType: result.messageType,
      ciphertext: result.ciphertext,
    );
  }

  /// Decrypts a message from [peerUserId]. Dispatches by message
  /// type: type 2 = PreKeySignalMessage (session is created on
  /// our side as a side effect), type 3 = SignalMessage (session
  /// must already exist). Session state is persisted on success.
  Future<Uint8List> decryptMessageFrom(
    String ownUserId,
    String peerUserId,
    int messageType,
    Uint8List ciphertext,
  ) async {
    await initialize();
    final identity = await _storage.loadIdentityKeyPair();
    if (identity == null) {
      throw StateError('no identity key; call generateInitialKeys() first');
    }
    final regId = deriveRegistrationId(identityPublicKey: identity.publicKey);

    if (messageType == 2) {
      // PreKey path — first message from this peer. We need to hand
      // libsignal our SignedPreKey, all unconsumed OTPKs, and all
      // unconsumed Kyber prekeys so it can pick the right ones the
      // incoming PKM references.
      final spk = await _storage.loadSignedPreKey();
      if (spk == null) {
        throw StateError('no signed prekey; call generateInitialKeys()');
      }

      final otpkIds = await _storage.listOneTimePreKeyIds();
      final otpkRecords = <Uint8List>[];
      for (final id in otpkIds) {
        final r = await _storage.loadOneTimePreKey(id);
        if (r != null) otpkRecords.add(r.serialized);
      }

      final kpkIds = await _storage.listKyberPreKeyIds();
      final kpkRecords = <Uint8List>[];
      for (final id in kpkIds) {
        final r = await _storage.loadKyberPreKey(id);
        if (r != null) kpkRecords.add(r.serialized);
      }

      final result = decryptPrekey1To1(
        ownUserId: ownUserId,
        remoteUserId: peerUserId,
        ownIdentitySerialized: identity.serialized,
        ownRegistrationId: regId,
        signedPrekeyRecordsSerialized: [spk.serialized],
        oneTimePrekeyRecordsSerialized: otpkRecords,
        kyberPrekeyRecordsSerialized: kpkRecords,
        ciphertext: ciphertext,
      );
      await _storage.saveSession(peerUserId, result.updatedSessionSerialized);
      return result.plaintext;
    } else {
      // Whisper / SignalMessage path — session must already exist.
      final session = await _storage.loadSession(peerUserId);
      if (session == null) {
        throw StateError(
          'no session with $peerUserId for SignalMessage decrypt',
        );
      }
      final result = decryptSignal1To1(
        ownUserId: ownUserId,
        remoteUserId: peerUserId,
        ownIdentitySerialized: identity.serialized,
        ownRegistrationId: regId,
        sessionSerialized: session,
        ciphertext: ciphertext,
      );
      await _storage.saveSession(peerUserId, result.updatedSessionSerialized);
      return result.plaintext;
    }
  }

  // ── Phase 1f: group sessions (Sender Keys) ─────────────────
  //
  // Each group conversation uses its conversation UUID as the
  // libsignal distribution_id. Every sender in the group maintains
  // their own chain keyed by (conversationId, ownUserId); receivers
  // collect the senders' records under (conversationId, peerId) as
  // SKDMs arrive.
  //
  // SKDM distribution (1:1-encrypting an SKDM, posting to each other
  // member, receiving SKDMs) is the caller's responsibility — this
  // client only owns the crypto. The conversation screen threads the
  // envelopes through the existing [encryptMessageFor] +
  // [decryptMessageFrom] 1:1 path.

  /// Ensures we have a sender-key chain for this group at the given
  /// conversation epoch. Three outcomes:
  ///   - We have a record AND its epoch matches [currentEpoch] →
  ///     returns null (no SKDM needed, just send).
  ///   - We have a record but it was generated under an older epoch
  ///     (membership changed server-side) → rotate: drop old record,
  ///     generate fresh chain, record new epoch, return new SKDM.
  ///   - We have no record → first send: generate, record epoch,
  ///     return SKDM.
  ///
  /// When non-null, the caller MUST 1:1-deliver the returned SKDM to
  /// every OTHER current member BEFORE sending any ciphertext
  /// encrypted from the new chain, or recipients will receive a
  /// group message they cannot decrypt.
  ///
  /// [currentEpoch] should come from the caller's freshly-fetched
  /// Conversation — using a stale cached value would let us send
  /// without rotating, and a removed member who retained a
  /// sender-key record would still be able to decrypt.
  Future<Uint8List?> ensureOwnGroupSenderKey({
    required String ownUserId,
    required String conversationId,
    required int currentEpoch,
  }) async {
    await initialize();
    final existing = await _storage.loadSenderKey(conversationId, ownUserId);
    final storedEpoch = await _storage.loadOwnSenderKeyEpoch(
      conversationId,
      ownUserId,
    );

    // Fast path — we're already in sync with this epoch, nothing to
    // distribute.
    if (existing != null &&
        storedEpoch != null &&
        storedEpoch >= currentEpoch) {
      return null;
    }

    // Rotation or first-send. Drop any prior record so libsignal
    // generates a fresh chain key rather than forking the existing
    // one — forward-secrecy matters here, a removed member who held
    // the old chain shouldn't be able to derive the new one.
    if (existing != null) {
      await _storage.deleteSenderKey(conversationId, ownUserId);
    }
    final out = createGroupSenderKey(
      ownUserId: ownUserId,
      conversationId: conversationId,
      existingOwnRecord: null,
    );
    await _storage.saveSenderKey(
      conversationId,
      ownUserId,
      out.updatedRecord,
    );
    await _storage.saveOwnSenderKeyEpoch(
      conversationId,
      ownUserId,
      currentEpoch,
    );
    return out.skdm;
  }

  /// Forcibly regenerates our sender-key chain. Call on membership
  /// change — the new SKDM must be redistributed to the CURRENT
  /// member set, so previously-trusted devices that have left can't
  /// decrypt anything new. Returns the fresh SKDM bytes.
  Future<Uint8List> rotateOwnGroupSenderKey({
    required String ownUserId,
    required String conversationId,
  }) async {
    await initialize();
    // Drop our prior record before creating — passing
    // `existing_own_record: None` to the Rust side generates an
    // entirely new chain key.
    await _storage.deleteSenderKey(conversationId, ownUserId);
    final out = createGroupSenderKey(
      ownUserId: ownUserId,
      conversationId: conversationId,
      existingOwnRecord: null,
    );
    await _storage.saveSenderKey(
      conversationId,
      ownUserId,
      out.updatedRecord,
    );
    return out.skdm;
  }

  /// Processes a peer's SKDM after the caller has 1:1-decrypted it
  /// via [decryptMessageFrom]. Merges into our sender-key store so
  /// subsequent group messages from that sender decrypt cleanly.
  Future<void> processGroupSenderKeyFrom({
    required String senderUserId,
    required String conversationId,
    required Uint8List skdmBytes,
  }) async {
    await initialize();
    final existing = await _storage.loadSenderKey(conversationId, senderUserId);
    final updated = processGroupSenderKey(
      senderUserId: senderUserId,
      conversationId: conversationId,
      skdmBytes: skdmBytes,
      existingSenderRecord: existing,
    );
    await _storage.saveSenderKey(conversationId, senderUserId, updated);
  }

  /// Encrypts `plaintext` for the group using our sender-key chain.
  /// Caller must have previously [ensureOwnGroupSenderKey]-ed or
  /// [rotateOwnGroupSenderKey]-ed; throws [StateError] otherwise.
  Future<Uint8List> encryptGroupMessage({
    required String ownUserId,
    required String conversationId,
    required Uint8List plaintext,
  }) async {
    await initialize();
    final ownRecord = await _storage.loadSenderKey(conversationId, ownUserId);
    if (ownRecord == null) {
      throw StateError(
        'no sender-key chain for conv=$conversationId; '
        'call ensureOwnGroupSenderKey() first',
      );
    }
    final result = encryptGroup(
      ownUserId: ownUserId,
      conversationId: conversationId,
      ownRecord: ownRecord,
      plaintext: plaintext,
    );
    await _storage.saveSenderKey(
      conversationId,
      ownUserId,
      result.updatedRecord,
    );
    return result.ciphertext;
  }

  /// Decrypts a group message from `senderUserId`. Throws
  /// [StateError] if we haven't yet processed their SKDM — the
  /// caller should buffer the ciphertext and retry when the SKDM
  /// arrives (it may be out-of-order relative to the group message).
  Future<Uint8List> decryptGroupMessage({
    required String senderUserId,
    required String conversationId,
    required Uint8List ciphertext,
  }) async {
    await initialize();
    final senderRecord =
        await _storage.loadSenderKey(conversationId, senderUserId);
    if (senderRecord == null) {
      throw StateError(
        'no sender-key record for sender=$senderUserId in '
        'conv=$conversationId (did their SKDM arrive?)',
      );
    }
    final result = decryptGroup(
      senderUserId: senderUserId,
      conversationId: conversationId,
      senderRecord: senderRecord,
      ciphertext: ciphertext,
    );
    await _storage.saveSenderKey(
      conversationId,
      senderUserId,
      result.updatedRecord,
    );
    return result.plaintext;
  }

  // ---- internals ----

  PublicKeyBundle _buildPublicBundle({
    required IdentityKeypair identity,
    required SignedPreKey spk,
    required List<OneTimePreKey> otpks,
    required List<KyberPreKey> kpks,
  }) {
    return PublicKeyBundle(
      identityPublic: identity.publicKey,
      signedPreKey: PublicSignedPreKey(
        id: spk.id,
        public: spk.publicKey,
        signature: spk.signature,
      ),
      oneTimePreKeys: otpks
          .map((o) => PublicOneTimePreKey(id: o.id, public: o.publicKey))
          .toList(growable: false),
      kyberPreKeys: kpks
          .map((k) => PublicKyberPreKey(
                id: k.id,
                public: k.publicKey,
                signature: k.signature,
              ))
          .toList(growable: false),
    );
  }
}
