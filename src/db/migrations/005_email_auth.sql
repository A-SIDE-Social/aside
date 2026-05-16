-- Migration 005: Switch from phone-based auth to email-based OTP
--
-- Adds email as the new identity column, makes phone_e164 nullable
-- (kept for existing users + legacy contact sync), and creates a
-- persistent OTP table replacing the in-memory store.

-- Add email as new identity column
ALTER TABLE users ADD COLUMN email text UNIQUE;

-- Add email_hash for contact sync (SHA-256 of lowercase email)
ALTER TABLE users ADD COLUMN email_hash text;
CREATE INDEX idx_users_email_hash ON users (email_hash);

-- Make phone_e164 nullable (existing users keep theirs)
ALTER TABLE users ALTER COLUMN phone_e164 DROP NOT NULL;

-- Persistent OTP storage (replaces in-memory otpStore map)
CREATE TABLE email_otps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  code_hash text NOT NULL,
  attempts integer NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_email_otps_email ON email_otps (email);
