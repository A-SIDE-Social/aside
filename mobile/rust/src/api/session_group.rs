// Phase 1f: Group E2EE via Signal's Sender Keys.
//
// Sender Keys is Signal's group-messaging protocol. Each sender in a
// group maintains their own hash-chain "sender key"; the key seed +
// chain position + signing public key are advertised to other
// members in a Sender Key Distribution Message (SKDM). Subsequent
// group messages from that sender are encrypted once with their
// sender key and broadcast to the whole group — each recipient
// decrypts with the stored sender key for that (sender, distribution)
// pair.
//
// Authentication story: SKDMs themselves are NOT signed by the
// identity key — they're delivered inside a 1:1 Double Ratchet
// session whose authenticity rides on the existing X3DH handshake.
// So "Bob knows this SKDM really came from Alice" rests on "Bob's
// 1:1 session with Alice was established against Alice's identity
// key." See docs/plans/e2ee.md §1f for the full distribution path.
//
// FFI shape mirrors `session_1to1`: each call rehydrates a fresh
// InMemSenderKeyStore from Dart-supplied record bytes, runs the
// async libsignal function via `futures::executor::block_on` (pure
// in-memory, cannot deadlock), then extracts the mutated record
// back for Dart to persist keyed by (distribution_id, sender_user_id).
//
// `distribution_id` is a `uuid::Uuid`; we take it from Dart as the
// conversation UUID string and parse. Using conversation_id directly
// is the standard Signal pattern — it stably identifies the group
// context without needing a separate identifier.

use futures::executor::block_on;
use libsignal_protocol::{
    DeviceId, InMemSenderKeyStore, ProtocolAddress, SenderKeyDistributionMessage, SenderKeyMessage,
    SenderKeyRecord, SenderKeyStore, create_sender_key_distribution_message, group_decrypt,
    group_encrypt, process_sender_key_distribution_message,
};
use uuid::Uuid;

/// Dart-facing result of [create_group_sender_key]. The sender
/// persists `updated_record` keyed by (conversation_id, own_user_id)
/// and fans out `skdm` to each other member, 1:1-encrypted via the
/// existing pairwise Double Ratchet sessions.
pub struct GroupSkdmOut {
    pub updated_record: Vec<u8>,
    pub skdm: Vec<u8>,
}

/// Dart-facing result of [encrypt_group]. `updated_record` must be
/// persisted before the ciphertext is delivered — the chain advances
/// on every send, so losing the updated state would force every
/// recipient to rebuild their sender-key store.
pub struct GroupEncryptResult {
    pub updated_record: Vec<u8>,
    pub ciphertext: Vec<u8>,
}

/// Dart-facing result of [decrypt_group]. Receiver persists the
/// `updated_record` so later messages in this chain (same sender,
/// same distribution) decrypt without re-processing.
pub struct GroupDecryptResult {
    pub updated_record: Vec<u8>,
    pub plaintext: Vec<u8>,
}

/// Common address convention shared with `session_1to1`: each peer is
/// keyed by user id + DeviceId(1). Single-device v1 — Phase 2
/// multi-device would thread a real device id through every call.
fn address_for(user_id: &str) -> anyhow::Result<ProtocolAddress> {
    Ok(ProtocolAddress::new(
        user_id.to_string(),
        DeviceId::new(1).map_err(|e| anyhow::anyhow!("device id: {e}"))?,
    ))
}

fn parse_distribution_id(conversation_id: &str) -> anyhow::Result<Uuid> {
    Uuid::parse_str(conversation_id)
        .map_err(|e| anyhow::anyhow!("conversation_id is not a UUID: {e}"))
}

/// Constructs a fresh store and, if we already have a record for
/// `(sender, distribution_id)`, loads it in. Used by every op here.
fn build_store_with(
    sender: &ProtocolAddress,
    distribution_id: Uuid,
    existing: Option<&[u8]>,
) -> anyhow::Result<InMemSenderKeyStore> {
    let mut store = InMemSenderKeyStore::new();
    if let Some(bytes) = existing {
        let record = SenderKeyRecord::deserialize(bytes)
            .map_err(|e| anyhow::anyhow!("record deserialize: {e}"))?;
        block_on(store.store_sender_key(sender, distribution_id, &record))
            .map_err(|e| anyhow::anyhow!("store_sender_key: {e}"))?;
    }
    Ok(store)
}

fn load_record(
    store: &mut InMemSenderKeyStore,
    sender: &ProtocolAddress,
    distribution_id: Uuid,
    context: &'static str,
) -> anyhow::Result<Vec<u8>> {
    let record = block_on(store.load_sender_key(sender, distribution_id))
        .map_err(|e| anyhow::anyhow!("load_sender_key after {context}: {e}"))?
        .ok_or_else(|| anyhow::anyhow!("record missing after {context}"))?;
    record
        .serialize()
        .map_err(|e| anyhow::anyhow!("record serialize: {e}"))
}

/// Generates (or rotates) our own sender-key chain for this group
/// conversation and returns the SKDM to distribute. Call on:
///   - First group send (no existing record).
///   - Membership change (caller passes `existing_own_record = None`
///     to force a fresh chain, so previously-trusted members lose
///     decrypt ability going forward).
///
/// The caller is responsible for 1:1-encrypting `skdm` to each other
/// current member and delivering it via their existing Double Ratchet
/// session before the first ciphertext encrypted from `updated_record`
/// is broadcast — otherwise recipients receive a group message they
/// cannot decrypt.
#[flutter_rust_bridge::frb(sync)]
pub fn create_group_sender_key(
    own_user_id: String,
    conversation_id: String,
    existing_own_record: Option<Vec<u8>>,
) -> anyhow::Result<GroupSkdmOut> {
    let sender = address_for(&own_user_id)?;
    let distribution_id = parse_distribution_id(&conversation_id)?;

    let mut store = build_store_with(&sender, distribution_id, existing_own_record.as_deref())?;

    let mut rng = rand::rng();
    let skdm = block_on(create_sender_key_distribution_message(
        &sender,
        distribution_id,
        &mut store,
        &mut rng,
    ))
    .map_err(|e| anyhow::anyhow!("create_sender_key_distribution_message: {e}"))?;

    let updated_record = load_record(&mut store, &sender, distribution_id, "create SKDM")?;
    Ok(GroupSkdmOut {
        updated_record,
        skdm: skdm.serialized().to_vec(),
    })
}

/// Receiver-side: consume a peer's SKDM and return the updated record
/// to persist. Caller should have already 1:1-decrypted the SKDM from
/// the sender's Double Ratchet envelope before this call.
#[flutter_rust_bridge::frb(sync)]
pub fn process_group_sender_key(
    sender_user_id: String,
    conversation_id: String,
    skdm_bytes: Vec<u8>,
    existing_sender_record: Option<Vec<u8>>,
) -> anyhow::Result<Vec<u8>> {
    let sender = address_for(&sender_user_id)?;
    let distribution_id = parse_distribution_id(&conversation_id)?;

    let mut store =
        build_store_with(&sender, distribution_id, existing_sender_record.as_deref())?;

    let skdm = SenderKeyDistributionMessage::try_from(skdm_bytes.as_slice())
        .map_err(|e| anyhow::anyhow!("SKDM parse: {e}"))?;

    block_on(process_sender_key_distribution_message(
        &sender,
        &skdm,
        &mut store,
    ))
    .map_err(|e| anyhow::anyhow!("process_sender_key_distribution_message: {e}"))?;

    load_record(&mut store, &sender, distribution_id, "process SKDM")
}

/// Sender-side: encrypt `plaintext` for the group. Requires an
/// existing sender-key record (create via [create_group_sender_key]
/// first if we don't have one). Returns the updated record (persist
/// immediately) and the ciphertext (broadcast to the group).
#[flutter_rust_bridge::frb(sync)]
pub fn encrypt_group(
    own_user_id: String,
    conversation_id: String,
    own_record: Vec<u8>,
    plaintext: Vec<u8>,
) -> anyhow::Result<GroupEncryptResult> {
    let sender = address_for(&own_user_id)?;
    let distribution_id = parse_distribution_id(&conversation_id)?;

    let mut store = build_store_with(&sender, distribution_id, Some(&own_record))?;

    let mut rng = rand::rng();
    let ciphertext: SenderKeyMessage = block_on(group_encrypt(
        &mut store,
        &sender,
        distribution_id,
        &plaintext,
        &mut rng,
    ))
    .map_err(|e| anyhow::anyhow!("group_encrypt: {e}"))?;

    let updated_record = load_record(&mut store, &sender, distribution_id, "group_encrypt")?;
    Ok(GroupEncryptResult {
        updated_record,
        ciphertext: ciphertext.serialized().to_vec(),
    })
}

/// Receiver-side: decrypt `ciphertext` sent by `sender_user_id` in
/// this group. Requires the sender's record (populated by a prior
/// [process_group_sender_key] call for this sender + distribution).
#[flutter_rust_bridge::frb(sync)]
pub fn decrypt_group(
    sender_user_id: String,
    conversation_id: String,
    sender_record: Vec<u8>,
    ciphertext: Vec<u8>,
) -> anyhow::Result<GroupDecryptResult> {
    let sender = address_for(&sender_user_id)?;
    let distribution_id = parse_distribution_id(&conversation_id)?;

    let mut store = build_store_with(&sender, distribution_id, Some(&sender_record))?;

    let plaintext = block_on(group_decrypt(&ciphertext, &mut store, &sender))
        .map_err(|e| anyhow::anyhow!("group_decrypt: {e}"))?;

    let updated_record = load_record(&mut store, &sender, distribution_id, "group_decrypt")?;
    Ok(GroupDecryptResult {
        updated_record,
        plaintext,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// End-to-end three-party round-trip: Alice creates a group sender
    /// key, distributes the SKDM to Bob and Carol, sends a group
    /// message — both receivers decrypt it. Then Bob sends a message
    /// too (his own sender key), Alice and Carol decrypt. Proves the
    /// wrapper correctly serializes state across every boundary and
    /// that distinct senders in the same distribution don't step on
    /// each other.
    #[test]
    fn alice_bob_carol_group_round_trip() {
        let conv_id = "123e4567-e89b-12d3-a456-426614174000".to_string();
        let alice = "alice".to_string();
        let bob = "bob".to_string();
        // Carol never sends in this test, only receives — her user id
        // doesn't flow through the FFI because the receiver side keys
        // records by SENDER id, not by recipient. We just need two
        // distinct receiver stores (represented as the two separate
        // `carol_rec_for_*` records below) to prove that identical
        // SKDMs delivered to two recipients each yield a working
        // per-recipient record.

        // Alice sets up her sender key + SKDM.
        let alice_skdm = create_group_sender_key(alice.clone(), conv_id.clone(), None).unwrap();

        // Bob + Carol process Alice's SKDM. Neither had a prior
        // record so `existing_sender_record = None`.
        let bob_rec_for_alice = process_group_sender_key(
            alice.clone(),
            conv_id.clone(),
            alice_skdm.skdm.clone(),
            None,
        )
        .unwrap();
        let carol_rec_for_alice = process_group_sender_key(
            alice.clone(),
            conv_id.clone(),
            alice_skdm.skdm.clone(),
            None,
        )
        .unwrap();

        // Alice encrypts the first group message.
        let msg1 = b"hello group from alice".to_vec();
        let alice_send1 = encrypt_group(
            alice.clone(),
            conv_id.clone(),
            alice_skdm.updated_record.clone(),
            msg1.clone(),
        )
        .unwrap();

        // Bob decrypts.
        let bob_got = decrypt_group(
            alice.clone(),
            conv_id.clone(),
            bob_rec_for_alice.clone(),
            alice_send1.ciphertext.clone(),
        )
        .unwrap();
        assert_eq!(bob_got.plaintext, msg1, "bob decrypts alice's message 1");

        // Carol decrypts.
        let carol_got = decrypt_group(
            alice.clone(),
            conv_id.clone(),
            carol_rec_for_alice.clone(),
            alice_send1.ciphertext,
        )
        .unwrap();
        assert_eq!(carol_got.plaintext, msg1, "carol decrypts alice's message 1");

        // Now Bob sends. His sender key chain is separate from
        // Alice's — he creates his own SKDM + distributes.
        let bob_skdm = create_group_sender_key(bob.clone(), conv_id.clone(), None).unwrap();

        let alice_rec_for_bob = process_group_sender_key(
            bob.clone(),
            conv_id.clone(),
            bob_skdm.skdm.clone(),
            None,
        )
        .unwrap();
        let carol_rec_for_bob =
            process_group_sender_key(bob.clone(), conv_id.clone(), bob_skdm.skdm, None).unwrap();

        let msg2 = b"bob's reply".to_vec();
        let bob_send1 = encrypt_group(
            bob.clone(),
            conv_id.clone(),
            bob_skdm.updated_record,
            msg2.clone(),
        )
        .unwrap();

        let alice_got = decrypt_group(
            bob.clone(),
            conv_id.clone(),
            alice_rec_for_bob,
            bob_send1.ciphertext.clone(),
        )
        .unwrap();
        assert_eq!(alice_got.plaintext, msg2, "alice decrypts bob's reply");

        let carol_got2 = decrypt_group(
            bob.clone(),
            conv_id.clone(),
            carol_rec_for_bob,
            bob_send1.ciphertext,
        )
        .unwrap();
        assert_eq!(carol_got2.plaintext, msg2, "carol decrypts bob's reply");

        // Alice sends a second message — this one uses her updated
        // record from send1. Bob uses his updated record from his
        // first decrypt of alice_send1.
        let msg3 = b"alice again".to_vec();
        let alice_send2 = encrypt_group(
            alice.clone(),
            conv_id.clone(),
            alice_send1.updated_record,
            msg3.clone(),
        )
        .unwrap();
        let bob_got2 = decrypt_group(
            alice,
            conv_id,
            bob_got.updated_record,
            alice_send2.ciphertext,
        )
        .unwrap();
        assert_eq!(bob_got2.plaintext, msg3, "bob decrypts alice's second message on the same chain");
    }
}
