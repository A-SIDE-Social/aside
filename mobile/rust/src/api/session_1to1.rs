// Phase 1e: 1:1 E2EE sessions via libsignal.
//
// Four sync FFI entry points, one per phase of a conversation:
//
//   initiate_1to1_session — Alice (initiator) turns a fetched peer
//       bundle into a fresh SessionRecord. Pairs with encrypt_1to1
//       for the first message, which will be a PreKeySignalMessage.
//
//   encrypt_1to1 — given a SessionRecord, encrypt a plaintext message.
//       Returns the updated SessionRecord + the ciphertext + the
//       CiphertextMessageType (2 = PreKeySignalMessage, 3 = regular
//       SignalMessage).
//
//   decrypt_prekey_1to1 — Bob (responder) turns an incoming
//       PreKeySignalMessage into plaintext, creating a SessionRecord
//       in the process. Consumes an OTPK + a Kyber prekey by id
//       (caller must load them into the stores before this call,
//       and delete them locally after).
//
//   decrypt_signal_1to1 — subsequent messages on an established
//       session. Plain SessionRecord + ciphertext → plaintext +
//       updated SessionRecord.
//
// Design: each call constructs fresh libsignal InMem*Stores from the
// Dart-supplied state, runs the async libsignal function via
// futures::executor::block_on (InMem stores don't do real I/O, so
// this can't deadlock), then extracts the mutated state back out to
// return to Dart. Session state lives in Dart-side storage (Keychain/
// Keystore), keyed by peer user id.

use std::time::SystemTime;

use libsignal_protocol::{
    kem,
    message_decrypt_prekey,
    message_decrypt_signal,
    message_encrypt,
    process_prekey_bundle,
    CiphertextMessageType,
    DeviceId,
    GenericSignedPreKey,
    IdentityKey,
    IdentityKeyPair,
    InMemIdentityKeyStore,
    InMemKyberPreKeyStore,
    InMemPreKeyStore,
    InMemSessionStore,
    InMemSignedPreKeyStore,
    KyberPreKeyId,
    KyberPreKeyRecord,
    // Storage trait impls — needed to call load_session, store_session,
    // save_pre_key, etc. on the InMem stores.
    KyberPreKeyStore,
    PreKeyBundle,
    PreKeyId,
    PreKeyRecord,
    PreKeySignalMessage,
    PreKeyStore,
    ProtocolAddress,
    SessionRecord,
    SessionStore,
    SignalMessage,
    SignedPreKeyId,
    SignedPreKeyRecord,
    SignedPreKeyStore,
};

use futures::executor::block_on;

/// Dart-facing result of encrypt_1to1.
pub struct EncryptResult {
    /// Updated session, to be persisted and used for the next encrypt.
    pub updated_session_serialized: Vec<u8>,
    /// Serialized CiphertextMessage bytes — this is what goes on the
    /// wire (base64-encoded into the message envelope).
    pub ciphertext: Vec<u8>,
    /// CiphertextMessageType tag: 2 for PreKeySignalMessage (first
    /// message in a session), 3 for a regular SignalMessage.
    pub message_type: i32,
}

/// Dart-facing result of decrypt_*.
pub struct DecryptResult {
    /// Updated session, to persist.
    pub updated_session_serialized: Vec<u8>,
    /// Recovered plaintext bytes.
    pub plaintext: Vec<u8>,
    /// One-time PreKey id referenced by a decrypted PreKeySignalMessage,
    /// if the sender used one. Dart deletes this local private key after
    /// a successful decrypt so local inventory tracks server consumption.
    pub consumed_one_time_prekey_id: Option<u32>,
    /// Kyber PreKey id referenced by a decrypted PreKeySignalMessage.
    /// Dart deletes this local private key after a successful decrypt.
    pub consumed_kyber_prekey_id: Option<u32>,
}

/// Common addressing convention: each peer is keyed by their user id
/// and hard-coded DeviceId(1) since v1 is single-device per user.
/// Phase 2 multi-device would thread the device id through every
/// call from Dart.
fn protocol_address_for(user_id: &str) -> anyhow::Result<ProtocolAddress> {
    Ok(ProtocolAddress::new(
        user_id.to_string(),
        DeviceId::new(1).map_err(|e| anyhow::anyhow!("invalid device id: {e}"))?,
    ))
}

/// Constructs an empty InMemSessionStore + InMemIdentityKeyStore
/// populated with our identity. Used by every call.
fn base_stores(
    identity_serialized: &[u8],
    registration_id: u32,
) -> anyhow::Result<(InMemSessionStore, InMemIdentityKeyStore)> {
    let identity = IdentityKeyPair::try_from(identity_serialized)
        .map_err(|e| anyhow::anyhow!("identity deserialize: {e}"))?;
    Ok((
        InMemSessionStore::new(),
        InMemIdentityKeyStore::new(identity, registration_id),
    ))
}

/// Alice-side session setup: consumes a peer's bundle, produces a
/// SessionRecord. Call this once per peer when you first establish
/// a session (before sending the first message).
///
/// Registration ID is the caller's own id (u32) used by libsignal as
/// a device identifier. Single-device v1 picks a fixed value at
/// identity creation time — we'll derive it from the identity key
/// bytes on the Dart side and pass here.
#[flutter_rust_bridge::frb(sync)]
#[allow(clippy::too_many_arguments)]
pub fn initiate_1to1_session(
    own_user_id: String,
    remote_user_id: String,
    own_identity_serialized: Vec<u8>,
    own_registration_id: u32,
    peer_registration_id: u32,
    peer_identity_pub: Vec<u8>,
    peer_signed_prekey_id: u32,
    peer_signed_prekey_pub: Vec<u8>,
    peer_signed_prekey_sig: Vec<u8>,
    peer_one_time_prekey_id: Option<u32>,
    peer_one_time_prekey_pub: Option<Vec<u8>>,
    peer_kyber_prekey_id: u32,
    peer_kyber_prekey_pub: Vec<u8>,
    peer_kyber_prekey_sig: Vec<u8>,
) -> anyhow::Result<Vec<u8>> {
    let _local_address = protocol_address_for(&own_user_id)?;
    let address = protocol_address_for(&remote_user_id)?;
    let (mut session_store, mut identity_store) =
        base_stores(&own_identity_serialized, own_registration_id)?;

    let peer_identity = IdentityKey::decode(&peer_identity_pub)
        .map_err(|e| anyhow::anyhow!("peer identity decode: {e}"))?;
    let peer_spk_pub = libsignal_protocol::PublicKey::deserialize(&peer_signed_prekey_pub)
        .map_err(|e| anyhow::anyhow!("peer signed prekey pub decode: {e}"))?;
    let peer_kyber_pub = kem::PublicKey::deserialize(&peer_kyber_prekey_pub)
        .map_err(|e| anyhow::anyhow!("peer kyber prekey pub decode: {e}"))?;

    let otpk_pair = match (peer_one_time_prekey_id, peer_one_time_prekey_pub) {
        (Some(id), Some(pub_bytes)) => {
            let pub_key = libsignal_protocol::PublicKey::deserialize(&pub_bytes)
                .map_err(|e| anyhow::anyhow!("peer otpk decode: {e}"))?;
            Some((PreKeyId::from(id), pub_key))
        }
        _ => None,
    };

    let bundle = PreKeyBundle::new(
        peer_registration_id,
        DeviceId::new(1).map_err(|e| anyhow::anyhow!("device id: {e}"))?,
        otpk_pair,
        SignedPreKeyId::from(peer_signed_prekey_id),
        peer_spk_pub,
        peer_signed_prekey_sig,
        KyberPreKeyId::from(peer_kyber_prekey_id),
        peer_kyber_pub,
        peer_kyber_prekey_sig,
        peer_identity,
    )
    .map_err(|e| anyhow::anyhow!("PreKeyBundle::new: {e}"))?;

    let mut rng = rand::rng();
    block_on(process_prekey_bundle(
        &address,
        &mut session_store,
        &mut identity_store,
        &bundle,
        SystemTime::now(),
        &mut rng,
    ))
    .map_err(|e| anyhow::anyhow!("process_prekey_bundle: {e}"))?;

    let record = block_on(session_store.load_session(&address))
        .map_err(|e| anyhow::anyhow!("load_session: {e}"))?
        .ok_or_else(|| anyhow::anyhow!("session was not created"))?;
    record
        .serialize()
        .map_err(|e| anyhow::anyhow!("session serialize: {e}"))
}

/// Encrypts `plaintext` against the session stored at `session_
/// serialized`. Returns the new session state (to persist) + the
/// ciphertext bytes (to send) + the message type tag.
#[flutter_rust_bridge::frb(sync)]
pub fn encrypt_1to1(
    own_user_id: String,
    remote_user_id: String,
    own_identity_serialized: Vec<u8>,
    own_registration_id: u32,
    session_serialized: Vec<u8>,
    plaintext: Vec<u8>,
) -> anyhow::Result<EncryptResult> {
    let remote_address = protocol_address_for(&remote_user_id)?;
    let local_address = protocol_address_for(&own_user_id)?;
    let (mut session_store, mut identity_store) =
        base_stores(&own_identity_serialized, own_registration_id)?;

    let record = SessionRecord::deserialize(&session_serialized)
        .map_err(|e| anyhow::anyhow!("session deserialize: {e}"))?;
    block_on(session_store.store_session(&remote_address, &record))
        .map_err(|e| anyhow::anyhow!("store_session: {e}"))?;

    let mut rng = rand::rng();
    let ciphertext = block_on(message_encrypt(
        &plaintext,
        &remote_address,
        &local_address,
        &mut session_store,
        &mut identity_store,
        SystemTime::now(),
        &mut rng,
    ))
    .map_err(|e| anyhow::anyhow!("message_encrypt: {e}"))?;

    let message_type = match ciphertext.message_type() {
        CiphertextMessageType::PreKey => 2,
        CiphertextMessageType::Whisper => 3,
        other => other as i32,
    };
    let ciphertext_bytes = ciphertext.serialize().to_vec();

    let updated = block_on(session_store.load_session(&remote_address))
        .map_err(|e| anyhow::anyhow!("load_session after encrypt: {e}"))?
        .ok_or_else(|| anyhow::anyhow!("session missing after encrypt"))?;
    let updated_bytes = updated
        .serialize()
        .map_err(|e| anyhow::anyhow!("session serialize: {e}"))?;

    Ok(EncryptResult {
        updated_session_serialized: updated_bytes,
        ciphertext: ciphertext_bytes,
        message_type,
    })
}

/// Responder-side first-message decrypt. Ciphertext must be a serialized
/// PreKeySignalMessage. Caller supplies the SignedPreKey + OneTimePreKey
/// + KyberPreKey records the message will reference — we don't know
/// which ids it references until libsignal parses it, so Dart passes
/// every unconsumed record (single-device v1 typically keeps the pool
/// small enough that this is fine).
#[flutter_rust_bridge::frb(sync)]
#[allow(clippy::too_many_arguments)]
pub fn decrypt_prekey_1to1(
    own_user_id: String,
    remote_user_id: String,
    own_identity_serialized: Vec<u8>,
    own_registration_id: u32,
    signed_prekey_records_serialized: Vec<Vec<u8>>,
    one_time_prekey_records_serialized: Vec<Vec<u8>>,
    kyber_prekey_records_serialized: Vec<Vec<u8>>,
    ciphertext: Vec<u8>,
) -> anyhow::Result<DecryptResult> {
    let remote_address = protocol_address_for(&remote_user_id)?;
    let local_address = protocol_address_for(&own_user_id)?;
    let (mut session_store, mut identity_store) =
        base_stores(&own_identity_serialized, own_registration_id)?;

    let mut spk_store = InMemSignedPreKeyStore::new();
    for bytes in signed_prekey_records_serialized {
        let record = SignedPreKeyRecord::deserialize(&bytes)
            .map_err(|e| anyhow::anyhow!("SPK deserialize: {e}"))?;
        let id = record.id().map_err(|e| anyhow::anyhow!("SPK id: {e}"))?;
        block_on(spk_store.save_signed_pre_key(id, &record))
            .map_err(|e| anyhow::anyhow!("SPK save: {e}"))?;
    }

    let mut otpk_store = InMemPreKeyStore::new();
    for bytes in one_time_prekey_records_serialized {
        let record = PreKeyRecord::deserialize(&bytes)
            .map_err(|e| anyhow::anyhow!("OTPK deserialize: {e}"))?;
        let id = record.id().map_err(|e| anyhow::anyhow!("OTPK id: {e}"))?;
        block_on(otpk_store.save_pre_key(id, &record))
            .map_err(|e| anyhow::anyhow!("OTPK save: {e}"))?;
    }

    let mut kyber_store = InMemKyberPreKeyStore::new();
    for bytes in kyber_prekey_records_serialized {
        let record = KyberPreKeyRecord::deserialize(&bytes)
            .map_err(|e| anyhow::anyhow!("Kyber deserialize: {e}"))?;
        let id = record.id().map_err(|e| anyhow::anyhow!("Kyber id: {e}"))?;
        block_on(kyber_store.save_kyber_pre_key(id, &record))
            .map_err(|e| anyhow::anyhow!("Kyber save: {e}"))?;
    }

    let pkm = PreKeySignalMessage::try_from(ciphertext.as_slice())
        .map_err(|e| anyhow::anyhow!("PreKeySignalMessage parse: {e}"))?;
    let consumed_one_time_prekey_id = pkm.pre_key_id().map(Into::<u32>::into);
    let consumed_kyber_prekey_id = pkm.kyber_pre_key_id().map(Into::<u32>::into);

    let mut rng = rand::rng();
    let plaintext = block_on(message_decrypt_prekey(
        &pkm,
        &remote_address,
        &local_address,
        &mut session_store,
        &mut identity_store,
        &mut otpk_store,
        &spk_store,
        &mut kyber_store,
        &mut rng,
    ))
    .map_err(|e| anyhow::anyhow!("message_decrypt_prekey: {e}"))?;

    let updated = block_on(session_store.load_session(&remote_address))
        .map_err(|e| anyhow::anyhow!("load_session after decrypt: {e}"))?
        .ok_or_else(|| anyhow::anyhow!("session missing after decrypt"))?;
    let updated_bytes = updated
        .serialize()
        .map_err(|e| anyhow::anyhow!("session serialize: {e}"))?;

    Ok(DecryptResult {
        updated_session_serialized: updated_bytes,
        plaintext,
        consumed_one_time_prekey_id,
        consumed_kyber_prekey_id,
    })
}

/// Subsequent-message decrypt on an established session. Ciphertext
/// must be a serialized SignalMessage (not PKM).
#[flutter_rust_bridge::frb(sync)]
pub fn decrypt_signal_1to1(
    own_user_id: String,
    remote_user_id: String,
    own_identity_serialized: Vec<u8>,
    own_registration_id: u32,
    session_serialized: Vec<u8>,
    ciphertext: Vec<u8>,
) -> anyhow::Result<DecryptResult> {
    let remote_address = protocol_address_for(&remote_user_id)?;
    let local_address = protocol_address_for(&own_user_id)?;
    let (mut session_store, mut identity_store) =
        base_stores(&own_identity_serialized, own_registration_id)?;

    let record = SessionRecord::deserialize(&session_serialized)
        .map_err(|e| anyhow::anyhow!("session deserialize: {e}"))?;
    block_on(session_store.store_session(&remote_address, &record))
        .map_err(|e| anyhow::anyhow!("store_session: {e}"))?;

    let msg = SignalMessage::try_from(ciphertext.as_slice())
        .map_err(|e| anyhow::anyhow!("SignalMessage parse: {e}"))?;

    let _unused_local_address = local_address; // future-proofing
    let mut rng = rand::rng();
    let plaintext = block_on(message_decrypt_signal(
        &msg,
        &remote_address,
        &mut session_store,
        &mut identity_store,
        &mut rng,
    ))
    .map_err(|e| anyhow::anyhow!("message_decrypt_signal: {e}"))?;

    let updated = block_on(session_store.load_session(&remote_address))
        .map_err(|e| anyhow::anyhow!("load_session after decrypt: {e}"))?
        .ok_or_else(|| anyhow::anyhow!("session missing after decrypt"))?;
    let updated_bytes = updated
        .serialize()
        .map_err(|e| anyhow::anyhow!("session serialize: {e}"))?;

    Ok(DecryptResult {
        updated_session_serialized: updated_bytes,
        plaintext,
        consumed_one_time_prekey_id: None,
        consumed_kyber_prekey_id: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use libsignal_protocol::{KeyPair, Timestamp};

    /// Full Alice → Bob round-trip via the FFI entry points: Alice
    /// initiates a session from Bob's bundle, encrypts a first
    /// message (PKM), Bob decrypts it. Proves the wrappers work
    /// end-to-end without needing an on-device build.
    #[test]
    fn alice_bob_first_message_round_trip() {
        let mut rng = rand::rng();

        let alice_identity = IdentityKeyPair::generate(&mut rng);
        let alice_id_bytes = alice_identity.serialize().to_vec();
        let alice_reg_id = 1u32;

        let bob_identity = IdentityKeyPair::generate(&mut rng);
        let bob_id_bytes = bob_identity.serialize().to_vec();
        let bob_reg_id = 2u32;

        let bob_spk_pair = KeyPair::generate(&mut rng);
        let bob_spk_id = 1u32;
        let bob_spk_sig = bob_identity
            .private_key()
            .calculate_signature(&bob_spk_pair.public_key.serialize(), &mut rng)
            .unwrap()
            .to_vec();

        let bob_otpk_pair = KeyPair::generate(&mut rng);
        let bob_otpk_id = 10u32;

        let bob_kyber_record = KyberPreKeyRecord::generate(
            kem::KeyType::Kyber1024,
            KyberPreKeyId::from(5u32),
            bob_identity.private_key(),
        )
        .unwrap();
        let bob_kyber_pub = bob_kyber_record.public_key().unwrap().serialize().to_vec();
        let bob_kyber_sig = bob_kyber_record.signature().unwrap();

        let alice_session = initiate_1to1_session(
            "alice".to_string(),
            "bob".to_string(),
            alice_id_bytes.clone(),
            alice_reg_id,
            bob_reg_id,
            bob_identity.identity_key().serialize().to_vec(),
            bob_spk_id,
            bob_spk_pair.public_key.serialize().to_vec(),
            bob_spk_sig.clone(),
            Some(bob_otpk_id),
            Some(bob_otpk_pair.public_key.serialize().to_vec()),
            5u32,
            bob_kyber_pub,
            bob_kyber_sig,
        )
        .unwrap();

        let plaintext = b"hello bob!".to_vec();
        let encrypted = encrypt_1to1(
            "alice".to_string(),
            "bob".to_string(),
            alice_id_bytes,
            alice_reg_id,
            alice_session,
            plaintext.clone(),
        )
        .unwrap();
        assert_eq!(
            encrypted.message_type, 2,
            "first message should be PKM (type 2)"
        );

        let spk_record = SignedPreKeyRecord::new(
            SignedPreKeyId::from(bob_spk_id),
            Timestamp::from_epoch_millis(0),
            &bob_spk_pair,
            &bob_spk_sig,
        );
        let otpk_record = PreKeyRecord::new(PreKeyId::from(bob_otpk_id), &bob_otpk_pair);

        let decrypted = decrypt_prekey_1to1(
            "bob".to_string(),
            "alice".to_string(),
            bob_id_bytes,
            bob_reg_id,
            vec![spk_record.serialize().unwrap()],
            vec![otpk_record.serialize().unwrap()],
            vec![bob_kyber_record.serialize().unwrap()],
            encrypted.ciphertext,
        )
        .unwrap();

        assert_eq!(decrypted.plaintext, plaintext, "round-trip plaintext match");
    }
}
