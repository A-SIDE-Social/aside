-- Build 38: track when each user last visited the Home feed.
--
-- Used by getUserBadgeCount() to compute the "new posts you
-- haven't seen yet" half of the app-icon badge. Users who have
-- never opened Home (or the column wasn't backfilled) fall back
-- to `users.created_at` so their first visit doesn't show every
-- post they've missed since signup as "unread."
--
-- Mobile bumps this via POST /v1/users/me/feed-seen each time
-- the Home tab is shown.

ALTER TABLE users ADD COLUMN last_feed_seen_at timestamptz;

-- Backfill existing users to NOW so the upgrade doesn't surface
-- a sudden flood of "new" posts as unread on first launch.
UPDATE users SET last_feed_seen_at = NOW() WHERE last_feed_seen_at IS NULL;
