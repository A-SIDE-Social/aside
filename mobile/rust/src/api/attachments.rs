// Phase 1g: DM attachment bulk encryption.
//
// The Double Ratchet envelope is great for small ciphertexts but
// adding 1-10MB image bytes to every message would explode bandwidth
// on the ratchet machinery and blow past typical push payload limits.
// Signal's approach — mirrored here — is:
//
//   1. Generate a random 256-bit file key per attachment.
//   2. AEAD-encrypt the image bytes locally with ChaCha20-Poly1305.
//   3. Upload the ciphertext blob to a separate (private) bucket.
//   4. Stuff only the `file_key` + blob reference + MIME type into
//      the E2EE message envelope — ~60 bytes, trivial.
//
// On receive: recipient decrypts the envelope to get the file key,
// downloads the ciphertext blob via short-TTL presigned URL, and
// decrypts it locally. Server never sees plaintext bytes.
//
// We use the standard "prepend the nonce to the ciphertext" layout
// so a single `Vec<u8>` on the wire carries everything the
// recipient needs.

use chacha20poly1305::{
    aead::{Aead, KeyInit},
    ChaCha20Poly1305, Key, Nonce,
};
use rand::RngCore;

const NONCE_LEN: usize = 12;
const KEY_LEN: usize = 32;

/// Generates a fresh 256-bit AEAD file key from the OS CSPRNG. Use
/// once per attachment — never reuse across blobs.
#[flutter_rust_bridge::frb(sync)]
pub fn generate_file_key() -> Vec<u8> {
    let mut rng = rand::rng();
    let mut key = [0u8; KEY_LEN];
    rng.fill_bytes(&mut key);
    key.to_vec()
}

/// Encrypts `plaintext` under `file_key` with a fresh random nonce.
/// Output layout: `[nonce(12) || ciphertext || tag(16)]`. The nonce
/// is prepended so the recipient can decrypt with just the file key
/// and the blob bytes — no separate nonce transport.
#[flutter_rust_bridge::frb(sync)]
pub fn encrypt_attachment(
    file_key: Vec<u8>,
    plaintext: Vec<u8>,
) -> anyhow::Result<Vec<u8>> {
    if file_key.len() != KEY_LEN {
        anyhow::bail!(
            "file_key must be {} bytes (got {})",
            KEY_LEN,
            file_key.len()
        );
    }
    let key = Key::from_slice(&file_key);
    let cipher = ChaCha20Poly1305::new(key);

    // Fresh random nonce per encryption. 12 bytes × 2^96 space is
    // fine for a per-attachment key that's only ever used once.
    let mut rng = rand::rng();
    let mut nonce_bytes = [0u8; NONCE_LEN];
    rng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_ref())
        .map_err(|e| anyhow::anyhow!("AEAD encrypt failed: {e}"))?;

    // Prepend nonce so the wire format is self-contained.
    let mut out = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

/// Decrypts a blob produced by [encrypt_attachment]. Reads the
/// nonce from the first 12 bytes, decrypts + authenticates the
/// rest. Throws if the blob is too short, the key is wrong, or
/// the tag doesn't verify (tampering / corruption).
#[flutter_rust_bridge::frb(sync)]
pub fn decrypt_attachment(
    file_key: Vec<u8>,
    ciphertext_with_nonce: Vec<u8>,
) -> anyhow::Result<Vec<u8>> {
    if file_key.len() != KEY_LEN {
        anyhow::bail!(
            "file_key must be {} bytes (got {})",
            KEY_LEN,
            file_key.len()
        );
    }
    if ciphertext_with_nonce.len() < NONCE_LEN + 16 {
        anyhow::bail!("ciphertext too short — missing nonce or tag");
    }
    let key = Key::from_slice(&file_key);
    let cipher = ChaCha20Poly1305::new(key);

    let (nonce_bytes, ct) = ciphertext_with_nonce.split_at(NONCE_LEN);
    let nonce = Nonce::from_slice(nonce_bytes);

    cipher
        .decrypt(nonce, ct)
        .map_err(|e| anyhow::anyhow!("AEAD decrypt failed: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_plaintext_matches() {
        let key = generate_file_key();
        let plaintext = b"hello attachment world".to_vec();
        let ciphertext = encrypt_attachment(key.clone(), plaintext.clone()).unwrap();
        // Ciphertext is strictly larger: nonce (12) + plaintext + tag (16).
        assert_eq!(ciphertext.len(), plaintext.len() + 12 + 16);
        let recovered = decrypt_attachment(key, ciphertext).unwrap();
        assert_eq!(recovered, plaintext);
    }

    #[test]
    fn two_encryptions_use_different_nonces() {
        let key = generate_file_key();
        let plaintext = b"same bytes".to_vec();
        let a = encrypt_attachment(key.clone(), plaintext.clone()).unwrap();
        let b = encrypt_attachment(key, plaintext).unwrap();
        // Same plaintext + same key should STILL produce different
        // ciphertexts because the nonce is random — critical for
        // AEAD nonce-misuse resistance.
        assert_ne!(a, b);
    }

    #[test]
    fn wrong_key_fails_decrypt() {
        let key1 = generate_file_key();
        let key2 = generate_file_key();
        let plaintext = b"secret".to_vec();
        let ct = encrypt_attachment(key1, plaintext).unwrap();
        assert!(decrypt_attachment(key2, ct).is_err());
    }

    #[test]
    fn tampered_ciphertext_fails_decrypt() {
        let key = generate_file_key();
        let plaintext = b"secret".to_vec();
        let mut ct = encrypt_attachment(key.clone(), plaintext).unwrap();
        // Flip a bit in the encrypted payload (not the nonce).
        ct[20] ^= 0x01;
        assert!(decrypt_attachment(key, ct).is_err());
    }

    #[test]
    fn large_blob_roundtrip() {
        let key = generate_file_key();
        // ~1 MB — representative of a typical photo.
        let plaintext = vec![0x42u8; 1_000_000];
        let ct = encrypt_attachment(key.clone(), plaintext.clone()).unwrap();
        let recovered = decrypt_attachment(key, ct).unwrap();
        assert_eq!(recovered.len(), plaintext.len());
        assert_eq!(recovered, plaintext);
    }
}
