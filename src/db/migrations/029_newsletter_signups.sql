-- Editorial newsletter consent is separate from app accounts and marketing_opt_in.
CREATE TABLE newsletter_signups (
  email text PRIMARY KEY,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  requested_at timestamptz NOT NULL DEFAULT now(),
  window_started_at timestamptz NOT NULL DEFAULT now(),
  request_count integer NOT NULL DEFAULT 1,
  completed_at timestamptz,
  confirmed_at timestamptz,
  consent_version text NOT NULL,
  source text NOT NULL,
  resend_contact_id text
);
CREATE INDEX newsletter_signups_cleanup ON newsletter_signups (requested_at)
  WHERE confirmed_at IS NULL;
