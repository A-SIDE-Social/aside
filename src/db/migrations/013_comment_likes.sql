-- Likes on comments. Mirrors post_likes (migration 008) exactly — same
-- shape, same cascade rules, same uniqueness guard. Kept as a separate
-- table rather than a polymorphic `likes` table so the FKs stay strict
-- and we don't grow a `target_type` column that would need indexing.
CREATE TABLE comment_likes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  comment_id uuid NOT NULL REFERENCES comments(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (comment_id, user_id)
);

CREATE INDEX idx_comment_likes_comment_id ON comment_likes (comment_id);
CREATE INDEX idx_comment_likes_user_id ON comment_likes (user_id);
