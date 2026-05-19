// Phase 1b (libsignal swap): signed and one-time prekeys as
// libsignal's canonical `SignedPreKeyRecord` and `PreKeyRecord`.
// Each record returned to Dart carries two byte views:
//
//   `serialized` — libsignal's protobuf form of the record, for
//                  secure storage and later protocol ops. Includes
//                  id, timestamp, keypair, and (for signed prekeys)
//                  signature.
//   `public_key` — the 33-byte public-half encoding that peers
//                  actually consume in key bundles.
//   `signature`  — only on signed prekeys, the 64-byte Ed25519
//                  signature produced with the IdentityKey.

use libsignal_protocol::{
    kem, GenericSignedPreKey, IdentityKeyPair, KeyPair, KyberPreKeyId, KyberPreKeyRecord, PreKeyId,
    PreKeyRecord, SignedPreKeyId, SignedPreKeyRecord, Timestamp,
};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct SignedPreKey {
    pub id: u32,
    pub serialized: Vec<u8>,
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

pub struct OneTimePreKey {
    pub id: u32,
    pub serialized: Vec<u8>,
    pub public_key: Vec<u8>,
}

/// A Kyber (post-quantum) prekey. libsignal hybridized its X3DH to
/// include a PQC leg so a future quantum attacker recording traffic
/// today can't later decrypt it. The key itself is ML-KEM-1024 (aka
/// Kyber1024) — ~1568-byte public half — signed by the IdentityKey's
/// Ed25519 signing capability.
///
/// Consumed one-per-session like a OneTimePreKey. Replenished from
/// the client when the unconsumed pool runs low.
pub struct KyberPreKey {
    pub id: u32,
    pub serialized: Vec<u8>,
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Generates a fresh X25519 keypair and signs its public half with
/// the IdentityKey loaded from `identity_serialized` (the opaque
/// blob stored at generation time). Returns both the protobuf
/// record (for storage) and the individual upload-ready bytes.
#[flutter_rust_bridge::frb(sync)]
pub fn generate_signed_prekey(
    identity_serialized: Vec<u8>,
    key_id: u32,
) -> anyhow::Result<SignedPreKey> {
    let identity = IdentityKeyPair::try_from(identity_serialized.as_slice())
        .map_err(|e| anyhow::anyhow!("bad identity keypair: {e}"))?;

    let mut rng = rand::rng();
    let keypair = KeyPair::generate(&mut rng);

    // Sign the public-key encoding with the identity private key.
    let spk_public_bytes = keypair.public_key.serialize();
    let signature = identity
        .private_key()
        .calculate_signature(&spk_public_bytes, &mut rng)
        .map_err(|e| anyhow::anyhow!("failed to sign signed prekey: {e}"))?
        .to_vec();

    let record = SignedPreKeyRecord::new(
        SignedPreKeyId::from(key_id),
        Timestamp::from_epoch_millis(now_millis()),
        &keypair,
        &signature,
    );

    Ok(SignedPreKey {
        id: key_id,
        serialized: record
            .serialize()
            .map_err(|e| anyhow::anyhow!("serialize signed prekey record: {e}"))?,
        public_key: spk_public_bytes.to_vec(),
        signature,
    })
}

/// Generates `count` One-Time PreKey records with sequential ids
/// starting at `start_id`. Typical first-run call is (1, 100).
///
/// Serialization failures would indicate a logic bug in libsignal
/// (not an input error), so we panic rather than bubble a Result —
/// frb 2.x can't SSE-encode Result<Vec<CustomStruct>> anyway.
#[flutter_rust_bridge::frb(sync)]
pub fn generate_prekey_batch(start_id: u32, count: u32) -> Vec<OneTimePreKey> {
    let mut rng = rand::rng();
    let mut out = Vec::with_capacity(count as usize);
    for i in 0..count {
        let id = start_id.saturating_add(i);
        let keypair = KeyPair::generate(&mut rng);
        let record = PreKeyRecord::new(PreKeyId::from(id), &keypair);
        out.push(OneTimePreKey {
            id,
            serialized: record
                .serialize()
                .expect("libsignal PreKeyRecord serialization failed"),
            public_key: keypair.public_key.serialize().to_vec(),
        });
    }
    out
}

/// Generates `count` Kyber prekey records signed by the identity
/// key loaded from `identity_serialized`. IDs are sequential starting
/// at `start_id`. Typical first-run call is `(identity, 1, 20)` —
/// batch is smaller than classical OTPKs because Kyber records are
/// ~3KB each.
#[flutter_rust_bridge::frb(sync)]
pub fn generate_kyber_prekey_batch(
    identity_serialized: Vec<u8>,
    start_id: u32,
    count: u32,
) -> Vec<KyberPreKey> {
    let identity = IdentityKeyPair::try_from(identity_serialized.as_slice())
        .expect("aside_crypto: identity keypair deserialize failed");
    let signing_key = identity.private_key();

    let mut out = Vec::with_capacity(count as usize);
    for i in 0..count {
        let id = start_id.saturating_add(i);
        let record = KyberPreKeyRecord::generate(
            kem::KeyType::Kyber1024,
            KyberPreKeyId::from(id),
            signing_key,
        )
        .expect("aside_crypto: Kyber keypair generation failed");

        // We expose three views of the same record:
        //   `serialized` — protobuf blob for local storage and
        //                  later libsignal Kyber-store population.
        //   `public_key` — the raw public-key bytes peers actually
        //                  consume during X3DH-PQC.
        //   `signature`  — the 64-byte Ed25519 signature over
        //                  public_key, same as classical SPKs.
        let public_key = record
            .public_key()
            .expect("aside_crypto: Kyber public_key extraction failed")
            .serialize()
            .to_vec();
        let signature = record
            .signature()
            .expect("aside_crypto: Kyber signature extraction failed");
        let serialized = record
            .serialize()
            .expect("aside_crypto: KyberPreKeyRecord serialization failed");

        out.push(KyberPreKey {
            id,
            serialized,
            public_key,
            signature,
        });
    }
    out
}

/// Verifies a Signed PreKey's signature against a given identity
/// public key. Useful for self-check before upload (Dart-side) and
/// for recipients verifying fetched bundles (Phase 1e).
#[flutter_rust_bridge::frb(sync)]
pub fn verify_signed_prekey(
    identity_public: Vec<u8>,
    signed_prekey_public: Vec<u8>,
    signature: Vec<u8>,
) -> anyhow::Result<bool> {
    use libsignal_protocol::IdentityKey;
    let id_key = match IdentityKey::decode(identity_public.as_slice()) {
        Ok(k) => k,
        Err(_) => return Ok(false),
    };
    Ok(id_key
        .public_key()
        .verify_signature(&signed_prekey_public, &signature))
}
