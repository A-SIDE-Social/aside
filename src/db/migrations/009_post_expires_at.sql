-- Add optional expiration for auto-hiding posts after a period (e.g. 24 hours)
ALTER TABLE posts ADD COLUMN expires_at timestamptz;
CREATE INDEX idx_posts_expires ON posts (expires_at) WHERE expires_at IS NOT NULL;
