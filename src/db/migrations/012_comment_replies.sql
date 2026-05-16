-- Comment replies: a comment can point at the comment it's replying to.
-- Flat storage, no threading UI — the FK lets us notify the parent's
-- author when someone replies, without needing to parse @-mentions out
-- of the body text.
ALTER TABLE comments
  ADD COLUMN reply_to_comment_id uuid REFERENCES comments(id) ON DELETE SET NULL;

-- Most comments aren't replies; partial index keeps this small and fast.
CREATE INDEX idx_comments_reply_to ON comments (reply_to_comment_id)
  WHERE reply_to_comment_id IS NOT NULL;

-- Add 'comment_reply' to the allowed notification types. When a reply
-- recipient is also the post author, we send this type only (more
-- specific wins) — see src/routes/comments.ts.
ALTER TABLE notifications DROP CONSTRAINT notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN ('inbound_follow', 'new_mutual', 'comment', 'dm', 'new_post', 'comment_reply'));
