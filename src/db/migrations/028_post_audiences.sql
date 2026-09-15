-- Privacy-preserving post audiences.
--
-- Existing posts remain visible to all mutual connections. Posts shared to
-- one or more private lists snapshot the eligible list members at publish
-- time so later list edits cannot silently broaden access to old content.

ALTER TABLE posts
  ADD COLUMN audience_type text NOT NULL DEFAULT 'all_connections'
  CHECK (audience_type IN ('all_connections', 'lists'));

CREATE TABLE post_audience_members (
  post_id uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id)
);

CREATE INDEX idx_post_audience_members_user_post
  ON post_audience_members (user_id, post_id);

-- Preserve the intent of any list-scoped posts created by older clients.
-- (Production had none when this migration was introduced, but the backfill
-- keeps fresh installs and non-production environments correct.)
INSERT INTO post_audience_members (post_id, user_id)
SELECT DISTINCT pg.post_id, gm.member_user_id
  FROM post_groups pg
  JOIN group_members gm ON gm.group_id = pg.group_id
ON CONFLICT DO NOTHING;

UPDATE posts p
   SET audience_type = 'lists'
 WHERE EXISTS (
   SELECT 1 FROM post_groups pg WHERE pg.post_id = p.id
 );
