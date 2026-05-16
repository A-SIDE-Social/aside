-- Store hashed phone numbers uploaded by each user for contact discovery
CREATE TABLE IF NOT EXISTS contact_hashes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  phone_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_contact_hashes_hash ON contact_hashes (phone_hash);
CREATE UNIQUE INDEX IF NOT EXISTS idx_contact_hashes_user_hash ON contact_hashes (user_id, phone_hash);

-- Store each user's own phone hash for reverse matching
ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_hash text;
CREATE INDEX IF NOT EXISTS idx_users_phone_hash ON users (phone_hash);

-- Backfill phone_hash for existing users
CREATE EXTENSION IF NOT EXISTS pgcrypto;
UPDATE users
  SET phone_hash = encode(digest(phone_e164, 'sha256'), 'hex')
  WHERE phone_hash IS NULL
    AND phone_e164 IS NOT NULL
    AND deleted_at IS NULL;
