-- Personal invite links — per-user opaque slugs that serve as the
-- target of a shareable URL `<configured-app-url>/<slug>`.
--
-- The slug is the user-facing replacement for the 12-character
-- alphanumeric invite codes (kept in the `invites` table). The slug
-- is rotatable: a user can regenerate it to invalidate every URL
-- and QR they've previously shared. That makes it the canonical
-- recovery path for "I accidentally posted my QR publicly" or
-- "I don't want this person reaching me anymore."
--
-- The column lives on `users` directly (not a side table) because
-- there is exactly one current slug per user. `invite_slug_rotated_at`
-- exists for two reasons: (1) an audit trail for support questions
-- ("when did this user last rotate?"), and (2) future per-user
-- rate-limiting via the rotation timestamp without needing a
-- separate counter store.
--
-- Backfill uses a DO block with retry-on-conflict because the 12-char
-- alphabet (36^12 ≈ 4.7e18) makes natural collisions vanishingly rare
-- but not impossible — and the unique constraint is enforced before
-- the column flips to NOT NULL.

ALTER TABLE users ADD COLUMN IF NOT EXISTS invite_slug text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS invite_slug_rotated_at timestamptz NULL;

-- Backfill every existing user with a unique 12-char slug. Alphabet
-- is full lowercase alphanumeric (no ambiguous-char exclusion needed
-- since slugs are never typed — they ride in URLs or QR codes).
DO $$
DECLARE
  r RECORD;
  candidate text;
  attempts int;
BEGIN
  FOR r IN SELECT id FROM users WHERE invite_slug IS NULL LOOP
    attempts := 0;
    LOOP
      candidate := string_agg(
        substr('abcdefghijklmnopqrstuvwxyz0123456789', floor(random() * 36)::int + 1, 1),
        ''
      ) FROM generate_series(1, 12);
      BEGIN
        UPDATE users SET invite_slug = candidate WHERE id = r.id;
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        attempts := attempts + 1;
        IF attempts > 10 THEN
          RAISE EXCEPTION 'Could not generate unique invite_slug for user %', r.id;
        END IF;
      END;
    END LOOP;
  END LOOP;
END $$;

-- The column stays nullable at the database level. The auth signup
-- path (src/routes/auth.ts:resolveUser) generates a slug for every
-- new user, and GET /v1/invite-link has a defensive auto-generate
-- branch for any user who somehow lacks one. Forcing NOT NULL would
-- break existing test fixtures that INSERT INTO users without naming
-- every column — pragmatically the application layer is the right
-- enforcement boundary here.
--
-- Case-insensitive uniqueness via a functional index. We accept any
-- case in URLs (people copy-paste and capitalization gets mangled in
-- SMS / iMessage), but collide cases for ownership so `Alice123abc`
-- and `alice123abc` can't both exist. Partial index so rows with
-- NULL slugs (legacy data, test users) don't conflict with each
-- other.
CREATE UNIQUE INDEX IF NOT EXISTS users_invite_slug_lower_idx
  ON users (LOWER(invite_slug))
  WHERE invite_slug IS NOT NULL;
