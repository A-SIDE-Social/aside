-- Emoji reactions on posts. Additive to post_likes (the heart stays
-- as the canonical "I liked this" affordance). A user can have
-- MULTIPLE reactions on the same post — one per (user, emoji) — so
-- the unique constraint is (post_id, user_id, emoji), not just
-- (post_id, user_id) like the likes table.
--
-- Skin-tone variants (👍🏻 vs 👍🏽) are stored as separate emoji
-- strings for v1; future migrations may add a normalized_emoji
-- column or a view that buckets variants. Storing the raw grapheme
-- now is the right primitive — normalization is purely additive
-- later.

CREATE TABLE IF NOT EXISTS post_reactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id UUID NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Bounded: a single grapheme cluster fits in ~16 bytes UTF-8 even
  -- with ZWJ sequences and skin-tone modifiers. Anything longer is
  -- garbage input that the route handler should also reject (via an
  -- Intl.Segmenter grapheme count) before reaching the DB.
  emoji TEXT NOT NULL CHECK (length(emoji) BETWEEN 1 AND 16),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (post_id, user_id, emoji)
);

-- Long-press sheet ("users who reacted with 🔥 on this post") filters
-- by (post_id, emoji) and orders by created_at DESC for pagination.
-- A plain post_id index doesn't cover that — this composite does.
CREATE INDEX IF NOT EXISTS post_reactions_post_emoji_created_idx
  ON post_reactions(post_id, emoji, created_at DESC);

-- For "what reactions did this user leave on these posts?" — used by
-- the feed enrichment that computes reacted_by_me per post per emoji.
CREATE INDEX IF NOT EXISTS post_reactions_user_id_idx
  ON post_reactions(user_id);
