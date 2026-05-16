-- Phase 1b.5 / Phase 1c: Kyber (post-quantum) prekeys.
--
-- Mirrors `one_time_prekeys` but for the PQC leg of libsignal's
-- hybrid X3DH. Consumed one-per-session; replenished from the
-- client when the unconsumed pool drops low.
--
-- The public key column is much larger than classical OTPKs
-- (~1568 bytes for Kyber1024 vs ~33 bytes for X25519), and there's
-- a signature column for the Ed25519 proof the identity key
-- generated the prekey.

CREATE TABLE kyber_prekeys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  key_id integer NOT NULL,
  key_pub bytea NOT NULL,
  signature bytea NOT NULL,

  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE (user_id, key_id)
);

CREATE INDEX idx_kyber_prekeys_unused
  ON kyber_prekeys (user_id)
  WHERE consumed_at IS NULL;
