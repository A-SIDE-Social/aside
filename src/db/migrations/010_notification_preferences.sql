-- Granular notification preferences per user
CREATE TABLE notification_preferences (
  user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  connections boolean NOT NULL DEFAULT true,
  posts boolean NOT NULL DEFAULT true,
  comments boolean NOT NULL DEFAULT true,
  messages boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);
