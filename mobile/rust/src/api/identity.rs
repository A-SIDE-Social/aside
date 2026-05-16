// Phase 1b (libsignal swap): identity keypair on top of
// signalapp/libsignal rather than raw dalek. Uses the canonical
// Signal Protocol type `IdentityKeyPair`, which is Curve25519 with
// XEdDSA so the same key can sign (Ed25519-shape) and do DH
// (X25519-shape). Byte shapes match what peers expect in key
// bundles, and the serialized form is what libsignal's higher-level
// code (X3DH, Double Ratchet) will consume in Phase 1e.

use libsignal_protocol::IdentityKeyPair;

/// An identity keypair.
///
///   `serialized` — libsignal's canonical protobuf encoding of the
///                  full keypair. Opaque to Dart; used for secure
///                  storage and as input to later protocol ops.
///   `public_key` — the 33-byte serialization of the public half
///                  (1-byte DJB type marker + 32-byte Curve25519
///                  public key). This is what goes in the uploaded
///                  key bundle.
pub struct IdentityKeypair {
    pub serialized: Vec<u8>,
    pub public_key: Vec<u8>,
}

/// Generates a fresh identity keypair backed by the OS CSPRNG
/// (seeded ThreadRng in rand 0.9 — ChaCha12 seeded from OS entropy).
#[flutter_rust_bridge::frb(sync)]
pub fn generate_identity_keypair() -> IdentityKeypair {
    let mut csprng = rand::rng();
    let kp = IdentityKeyPair::generate(&mut csprng);
    IdentityKeypair {
        serialized: kp.serialize().to_vec(),
        public_key: kp.identity_key().serialize().to_vec(),
    }
}

/// Deserializes an identity keypair and returns just the public-key
/// bytes. Used by tests (round-trip check) and by Dart code that
/// only has the serialized blob in storage and needs to re-derive
/// the public half for upload.
#[flutter_rust_bridge::frb(sync)]
pub fn identity_public_from_serialized(serialized: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    let kp = IdentityKeyPair::try_from(serialized.as_slice())
        .map_err(|e| anyhow::anyhow!("failed to deserialize identity keypair: {e}"))?;
    Ok(kp.identity_key().serialize().to_vec())
}

/// A version sentinel the Dart smoke test can read to confirm it's
/// actually talking to our Rust lib.
#[flutter_rust_bridge::frb(sync)]
pub fn crypto_version() -> String {
    concat!(
        "aside_crypto ",
        env!("CARGO_PKG_VERSION"),
        " / libsignal-protocol (git/main)"
    )
    .to_string()
}

/// Deterministically derives a libsignal registration id from an
/// identity public key. Same algorithm both sides, so peers compute
/// each other's registration id without it being on the wire —
/// saves a schema change. Identity public keys are already ~random
/// so taking the first 4 bytes is uniformly distributed.
///
/// Accepts both 32-byte raw Curve25519 public keys and 33-byte
/// DJB-prefixed IdentityKey encodings — offsets past the type byte
/// when present so both alice-self-deriving and bob-peer-deriving
/// get the same answer.
#[flutter_rust_bridge::frb(sync)]
pub fn derive_registration_id(identity_public_key: Vec<u8>) -> u32 {
    let bytes = if identity_public_key.len() == 33 {
        &identity_public_key[1..]
    } else {
        identity_public_key.as_slice()
    };
    if bytes.len() < 4 {
        return 1;
    }
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}
