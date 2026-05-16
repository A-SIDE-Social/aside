-- Group DMs (Phase 0 of the E2EE branch — plaintext for now).
--
-- The existing `conversations` table is hard-coded to 2-party via the
-- UNIQUE (user_a_id, user_b_id) and CHECK (user_a_id < user_b_id)
-- constraints. This migration generalizes it:
--
--   - Direct conversations keep their 2-party invariant (user_a_id,
--     user_b_id populated, canonically ordered, uniquely indexed).
--   - Group conversations leave user_a_id / user_b_id NULL and rely on
--     `conversation_members` alone for membership. They carry a name
--     and a creator reference.
--
-- One composite CHECK enforces the two shapes; a partial UNIQUE index
-- keeps 1:1 dedup working without blocking groups.

ALTER TABLE conversations
  ADD COLUMN conversation_type text NOT NULL DEFAULT 'direct'
    CHECK (conversation_type IN ('direct', 'group')),
  ADD COLUMN name text,
  ADD COLUMN created_by uuid REFERENCES users(id);

-- Relax so group chats can leave user_a/user_b NULL.
ALTER TABLE conversations
  ALTER COLUMN user_a_id DROP NOT NULL,
  ALTER COLUMN user_b_id DROP NOT NULL;

-- Drop the 2-person-specific constraints. The auto-named CHECK holds
-- user_a < user_b; we re-add it below scoped to directs only.
ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_user_a_id_user_b_id_key;
ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_check;

-- Combined shape check. Exactly one of the two forms must hold.
-- Name length 1–50 for groups (slightly stricter than the 100-char
-- soft UI limit we'll apply client-side, leaves headroom).
ALTER TABLE conversations ADD CONSTRAINT conversations_shape_check
  CHECK (
    (conversation_type = 'direct'
      AND name IS NULL
      AND user_a_id IS NOT NULL
      AND user_b_id IS NOT NULL
      AND user_a_id < user_b_id)
    OR
    (conversation_type = 'group'
      AND name IS NOT NULL
      AND char_length(name) BETWEEN 1 AND 50
      AND user_a_id IS NULL
      AND user_b_id IS NULL)
  );

-- 1:1 dedup lives on a partial unique index so it doesn't fire for
-- groups (which have NULL on both columns and would otherwise allow
-- any number of identical NULL pairs anyway, but the partial index
-- keeps intent explicit).
CREATE UNIQUE INDEX idx_conversations_direct_pair
  ON conversations (user_a_id, user_b_id)
  WHERE conversation_type = 'direct';
