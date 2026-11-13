-- A recovered messaging identity belongs to the confirming login session.
-- Keep this binding after session deletion: NULL must never mean that a
-- protected registration has fallen back to legacy account-wide revocation.
ALTER TABLE device_keys ADD COLUMN owner_session_id UUID;

-- Login codes and device-change confirmations are not interchangeable.
-- Issuance retains the existing per-address lock and shared resend cooldown.
ALTER TABLE email_otps ADD COLUMN purpose TEXT NOT NULL DEFAULT 'login'
  CHECK (purpose IN ('login', 'messaging-device-change'));
