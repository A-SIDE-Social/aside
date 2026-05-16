-- Migration 024: marketing-broadcast plumbing.
--
-- Two additions:
--   1. Per-user opt-in flag for product / marketing email blasts.
--      Default `true` because signing up implies consent for product
--      announcements (per TOS); the opt-out link in every broadcast
--      footer flips it to false.
--   2. `broadcasts` table — audit log of every send, what template
--      went out, how many recipients, who initiated. Surfaced in the
--      admin /admin/broadcast page so we don't accidentally re-send
--      the same template hours later.

ALTER TABLE users ADD COLUMN marketing_opt_in boolean NOT NULL DEFAULT true;
ALTER TABLE users ADD COLUMN marketing_opted_out_at timestamptz;

-- Index just on the opted-out subset (small set; most users opted in).
CREATE INDEX idx_users_marketing_opt_in
  ON users (marketing_opt_in)
  WHERE marketing_opt_in = false;

CREATE TABLE broadcasts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Template identifier (e.g., 'launch_announcement') — matches a
  -- key in src/marketing/templates/index.ts.
  template_key text NOT NULL,
  subject text NOT NULL,
  -- Operator who initiated the send. References users.id so we can
  -- show who sent what in the admin audit page.
  initiated_by_user_id uuid NOT NULL REFERENCES users(id),
  -- How many opted-in users were targeted vs. successfully sent.
  -- Discrepancy = Resend errors mid-batch (which we log + tolerate).
  recipient_count integer NOT NULL,
  send_count integer NOT NULL DEFAULT 0,
  failure_count integer NOT NULL DEFAULT 0,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  -- Optional payload for template-specific variables (none today,
  -- but plumbed for future templates that might take e.g. a
  -- {feature_name} variable).
  variables jsonb
);
CREATE INDEX idx_broadcasts_started ON broadcasts (started_at DESC);
