import { query } from './db/pool';
import { config } from './config';
import { resolveStorageUrl } from './storage';
import { AppError } from './middleware/errorHandler';

/**
 * Parse a `before=` pagination cursor. Cursors are ISO-8601 timestamps
 * (the `created_at` of the last item the client received). Returns `null`
 * for an absent cursor, or throws a 400 if the value is present but not a
 * parseable timestamp — historically a malformed cursor would reach the SQL
 * layer and surface as a 500 from `invalid input syntax for type timestamp
 * with time zone`. This helper turns that into a clean client error.
 *
 * Exported for unit testing.
 */
export function parseBeforeCursor(value: unknown): string | null {
  if (value == null || value === '') return null;
  if (typeof value !== 'string') {
    throw new AppError(400, 'before cursor must be a timestamp string');
  }
  const ms = Date.parse(value);
  if (Number.isNaN(ms)) {
    throw new AppError(400, 'before cursor must be a valid ISO-8601 timestamp');
  }
  return value;
}

export async function isMutualFollow(userA: string, userB: string): Promise<boolean> {
  const { rows } = await query(
    `SELECT EXISTS (
      SELECT 1 FROM follows f1
      JOIN follows f2
        ON f2.follower_id = f1.followee_id
        AND f2.followee_id = f1.follower_id
      WHERE f1.follower_id = $1
        AND f1.followee_id = $2
    ) AS is_mutual`,
    [userA, userB],
  );
  return rows[0].is_mutual;
}

export function asyncHandler(fn: Function) {
  return (req: any, res: any, next: any) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
}

/**
 * Resolve a media key to a full URL.
 * In dev, keys are filenames served by the local upload endpoint.
 * In prod, keys are S3 object keys served via CloudFront.
 */
export function resolveMediaUrl(key: string, req: any): string {
  if (!key) return key;
  // Already a full URL
  if (key.startsWith('http://') || key.startsWith('https://')) return key;
  const isDev = config.nodeEnv === 'development' || config.nodeEnv === 'test';
  if (isDev) {
    const host = req.get('x-forwarded-host') || req.get('host');
    const proto = req.get('x-forwarded-proto') || req.protocol;
    const baseUrl = `${proto}://${host}`;
    return `${baseUrl}/v1/posts/upload/${key}`;
  }
  return resolveStorageUrl(key);
}

/** Look up a user's subscription_status for plan-gating. */
export async function getUserSubscriptionStatus(userId: string): Promise<string> {
  const { rows } = await query(
    'SELECT subscription_status FROM users WHERE id = $1',
    [userId],
  );
  return rows[0]?.subscription_status ?? 'expired';
}

/** Resolve media_url and thumbnail_url for all media items attached to posts. */
export function resolvePostMedia(posts: any[], req: any): void {
  for (const post of posts) {
    if (post.media) {
      for (const m of post.media) {
        m.media_url = resolveMediaUrl(m.media_url, req);
        if (m.thumbnail_url) {
          m.thumbnail_url = resolveMediaUrl(m.thumbnail_url, req);
        }
      }
    }
    if (post.avatar_url) {
      post.avatar_url = resolveMediaUrl(post.avatar_url, req);
    }
  }
}
