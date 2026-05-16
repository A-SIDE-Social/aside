-- Migration 023: admin_audit table for the operator-facing /admin
-- dashboard. Every mutation made through the admin UI inserts a row
-- here so there's a tamper-resistant trail of who-changed-what-when.
-- Reads from the dashboard don't write rows; only mutations.
--
-- The admin gate is env-var allowlisted (`ADMIN_USER_IDS`); this
-- table doesn't replace that check, just records its outcomes.

CREATE TABLE admin_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL REFERENCES users(id),
  -- e.g. 'change_email', 'revoke_sessions', 'soft_delete', 'restore'
  action text NOT NULL,
  -- The user who was acted on. NULL for non-user-targeted actions.
  target_user_id uuid REFERENCES users(id),
  -- Action-specific payload: before/after values, counts, etc.
  -- Example for change_email:
  --   {"from":"old@example.com","to":"new@example.com","email_otps_cleared":2}
  details jsonb,
  ip_address text,
  user_agent text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Recent-first index for the audit page's default sort.
CREATE INDEX idx_admin_audit_created ON admin_audit (created_at DESC);
-- Per-admin scope when there are eventually multiple admins.
CREATE INDEX idx_admin_audit_admin
  ON admin_audit (admin_user_id, created_at DESC);
-- Look up the audit history of a specific target user.
CREATE INDEX idx_admin_audit_target
  ON admin_audit (target_user_id, created_at DESC)
  WHERE target_user_id IS NOT NULL;
