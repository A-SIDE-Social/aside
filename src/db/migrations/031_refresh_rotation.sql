-- One row remains the revocable session. Used credentials retain only hashes
-- so retries can be distinguished from replay without storing bearer secrets.
ALTER TABLE refresh_tokens ADD COLUMN rotation_enabled boolean NOT NULL DEFAULT false;
CREATE TABLE refresh_token_rotations (
  token_hash text PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES refresh_tokens(id) ON DELETE CASCADE,
  request_hash text NOT NULL,
  next_hash text NOT NULL,
  used_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_refresh_rotations_session ON refresh_token_rotations(session_id);
