-- Grant +20 pending invite codes to every non-deleted existing user.
--
-- One-off backfill to give existing TestFlight users more codes to share.
-- New signups get 25 at registration (auth.ts); existing users were stuck
-- with whatever they had before that change landed. The app-level cap of
-- 25 is only enforced at *generation* time, not on read, so adding 20
-- extra pending codes to accounts that may already be above 25 is fine.
--
-- ON CONFLICT DO NOTHING guards against the (astronomically unlikely)
-- 12-char UUID-prefix collision; worst case a user gets 19 instead of 20.
-- Soft-deleted users (deleted_at IS NOT NULL) are skipped.

INSERT INTO invites (created_by_user_id, code, status, expires_at)
SELECT
  u.id,
  SUBSTRING(gen_random_uuid()::text FROM 1 FOR 12),
  'pending',
  NOW() + INTERVAL '30 days'
FROM users u
CROSS JOIN generate_series(1, 20)
WHERE u.deleted_at IS NULL
ON CONFLICT (code) DO NOTHING;
