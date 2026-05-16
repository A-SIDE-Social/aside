-- Top up every non-deleted user to the current `maxInvites` (25) cap
-- of redeemable codes (status pending or sent).
--
-- This fixes a class of users who landed with fewer than 25 codes
-- because the signup-time allocation loop in auth.ts could throw on
-- a 12-char UUID-prefix collision after the `users` row had already
-- been inserted (no surrounding transaction). On retry, the existing-
-- user branch returned the row without re-running allocation, so the
-- user was stranded with 0 (or partial) codes. The follow-up code fix
-- adds `ON CONFLICT DO NOTHING` + retry; this migration brings the
-- existing population back to parity.
--
-- We count only redeemable statuses ('pending' + 'sent') so users who
-- legitimately consumed codes don't get rebackfilled past the cap.
-- 'used'/'revoked'/'expired' codes don't count toward the top-up.
--
-- ON CONFLICT (code) DO NOTHING guards against the same UUID-prefix
-- collision the original loop didn't handle.

WITH need AS (
  SELECT
    u.id,
    GREATEST(0, 25 - COUNT(i.id) FILTER (
      WHERE i.status IN ('pending', 'sent')
    )::int) AS missing
  FROM users u
  LEFT JOIN invites i ON i.created_by_user_id = u.id
  WHERE u.deleted_at IS NULL
  GROUP BY u.id
)
INSERT INTO invites (created_by_user_id, code, status, expires_at)
SELECT
  n.id,
  SUBSTRING(gen_random_uuid()::text FROM 1 FOR 12),
  'pending',
  NOW() + INTERVAL '30 days'
FROM need n
CROSS JOIN LATERAL generate_series(1, n.missing) AS gs
WHERE n.missing > 0
ON CONFLICT (code) DO NOTHING;
