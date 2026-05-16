-- One-time prekeys (OTPKs). Each row is consumed exactly once — a
-- peer picks one during X3DH, the server atomically marks it used,
-- and it's never reused. Clients top up when the unconsumed count
-- drops below the replenish threshold (default 20).
--
-- Keyed by (user_id, key_id) to match the single-device v1 shape of
-- device_keys. Same v2 migration path applies.

CREATE TABLE one_time_prekeys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  -- Client-assigned monotonically-increasing id. Stays stable so
  -- we can acknowledge consumption by id to the client and let it
  -- drop the corresponding private key.
  key_id integer NOT NULL,
  key_pub bytea NOT NULL,

  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),

  -- Same (user_id, key_id) uniqueness prevents replenish-after-rotate
  -- id collisions. Client is responsible for picking a start_id past
  -- its previous max — server enforces with this constraint.
  UNIQUE (user_id, key_id)
);

-- Partial index of unconsumed OTPKs — this is the hot path for
-- `GET /v1/users/:id/keybundle` picking one to hand out. Full
-- scans of consumed rows are never needed.
CREATE INDEX idx_one_time_prekeys_unused
  ON one_time_prekeys (user_id)
  WHERE consumed_at IS NULL;
