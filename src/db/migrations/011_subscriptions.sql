-- Track which plan type a user has (orthogonal to subscription_status)
ALTER TABLE users ADD COLUMN subscription_plan text NOT NULL DEFAULT 'free'
  CHECK (subscription_plan IN ('free', 'pro_individual', 'pro_family'));
ALTER TABLE users ADD COLUMN subscription_period_end timestamptz;
ALTER TABLE users ADD COLUMN family_group_id uuid;

-- Family groups (owner is the subscriber)
CREATE TABLE family_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE users ADD CONSTRAINT fk_family_group
  FOREIGN KEY (family_group_id) REFERENCES family_groups(id) ON DELETE SET NULL;

CREATE INDEX idx_users_family_group ON users(family_group_id) WHERE family_group_id IS NOT NULL;

-- Webhook idempotency log
CREATE TABLE revenuecat_webhook_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id text UNIQUE NOT NULL,
  event_type text NOT NULL,
  app_user_id text NOT NULL,
  payload jsonb NOT NULL,
  processed_at timestamptz NOT NULL DEFAULT now()
);
