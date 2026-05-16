-- Per-user Signal Protocol identity + signed prekey.
--
-- Keyed by user_id directly (not by a devices table) because v1 is
-- single-device per user — locked decision #5 in the E2EE plan.
-- When multi-device lands in v2, this migrates to FK(devices.id).
--
-- `revoked_at` lets us keep historical rows for audit / key-change
-- anomaly detection rather than hard-deleting. A partial unique
-- index enforces at most one active row per user; re-upload after
-- sign-out works because the previous row is marked revoked.

CREATE TABLE device_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  -- 33-byte libsignal-encoded public identity key (DJB type marker
  -- + 32-byte Curve25519 public). Stays the same for the life of
  -- the device; rotation means a new install.
  identity_key_pub bytea NOT NULL,

  -- Signed prekey. Rotated ~weekly. Signature is the IdentityKey's
  -- Ed25519 signature over the public-key bytes (64 bytes).
  signed_prekey_id integer NOT NULL,
  signed_prekey_pub bytea NOT NULL,
  signed_prekey_sig bytea NOT NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  rotated_at timestamptz,
  revoked_at timestamptz
);

-- At most one active (non-revoked) key set per user.
CREATE UNIQUE INDEX idx_device_keys_user_active
  ON device_keys (user_id)
  WHERE revoked_at IS NULL;

-- Sanity indexes for the common lookups.
CREATE INDEX idx_device_keys_user_id ON device_keys (user_id);
