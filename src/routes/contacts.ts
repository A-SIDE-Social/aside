import { Router } from 'express';
import crypto from 'crypto';
import { query } from '../db/pool';
import { asyncHandler, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { writeLimit } from '../middleware/rateLimit';
import { SYSTEM_USER_EMAIL } from '../constants';

const router = Router();

/**
 * Hash a phone number (E.164 format) using SHA-256.
 */
function hashPhone(phone: string): string {
  return crypto.createHash('sha256').update(phone).digest('hex');
}

/**
 * POST /sync — Upload hashed phone contacts, get matched A/SIDE users.
 *
 * Body: { hashes: string[] }
 * Response: { matches: [{ id, display_name, avatar_url, is_mutual }] }
 *
 * Pure read-side: stores the caller's contact hashes for future
 * cached `GET /matches` calls and returns matched users with their
 * current `is_mutual` follow state. We do NOT auto-create follows
 * from contact intersections — that surprises users (suddenly
 * following someone they didn't choose) and complicates App Review
 * disclosure. If user A wants to follow B, they tap Connect; if B
 * already followed A, /follows reports the result as mutual and
 * fires the new_mutual notification path automatically.
 */
router.post(
  '/sync',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { hashes } = req.body;

    if (!Array.isArray(hashes) || hashes.length === 0) {
      throw new AppError(400, 'hashes array is required');
    }

    // Cap at 5000 contacts per sync to prevent abuse
    const limitedHashes = hashes.slice(0, 5000);

    // Ensure the current user's own phone_hash is set
    const { rows: currentUser } = await query(
      'SELECT phone_e164, phone_hash, email_hash FROM users WHERE id = $1',
      [userId],
    );
    if (currentUser.length > 0 && currentUser[0].phone_e164 && !currentUser[0].phone_hash) {
      const myHash = hashPhone(currentUser[0].phone_e164);
      await query('UPDATE users SET phone_hash = $1 WHERE id = $2', [myHash, userId]);
    }

    // Upsert all contact hashes — delete old ones first, then bulk insert
    await query('DELETE FROM contact_hashes WHERE user_id = $1', [userId]);

    if (limitedHashes.length > 0) {
      // Build bulk insert values
      const values: string[] = [];
      const params: any[] = [userId];
      limitedHashes.forEach((hash: string, i: number) => {
        values.push(`($1, $${i + 2})`);
        params.push(hash);
      });

      await query(
        `INSERT INTO contact_hashes (user_id, phone_hash) VALUES ${values.join(', ')}
         ON CONFLICT (user_id, phone_hash) DO NOTHING`,
        params,
      );
    }

    // Find matches: other users whose phone_hash or email_hash
    // appears in our uploaded contacts. `is_mutual` reflects the
    // CURRENT follow state — if both directions already exist
    // (organically, not from contact sync) we surface that to the
    // client. We never write to the follows table from this route.
    const { rows: matches } = await query(
      `SELECT u.id, u.display_name, u.avatar_url,
              EXISTS (
                SELECT 1 FROM follows f1
                JOIN follows f2 ON f2.follower_id = f1.followee_id AND f2.followee_id = f1.follower_id
                WHERE f1.follower_id = $1 AND f1.followee_id = u.id
              ) AS is_mutual
       FROM users u
       JOIN contact_hashes ch ON (ch.phone_hash = u.phone_hash OR ch.phone_hash = u.email_hash) AND ch.user_id = $1
       WHERE u.id != $1
         AND u.deleted_at IS NULL
         AND u.email != $2`,
      [userId, SYSTEM_USER_EMAIL],
    );

    // Resolve avatar URLs
    for (const match of matches) {
      if (match.avatar_url) match.avatar_url = resolveMediaUrl(match.avatar_url, req);
    }

    res.json({ matches });
  }),
);

/**
 * GET /matches — Get cached contact matches from last sync.
 */
router.get(
  '/matches',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    const { rows: matches } = await query(
      `SELECT u.id, u.display_name, u.avatar_url,
              EXISTS (
                SELECT 1 FROM follows f1
                JOIN follows f2 ON f2.follower_id = f1.followee_id AND f2.followee_id = f1.follower_id
                WHERE f1.follower_id = $1 AND f1.followee_id = u.id
              ) AS is_mutual
       FROM users u
       JOIN contact_hashes ch ON (ch.phone_hash = u.phone_hash OR ch.phone_hash = u.email_hash) AND ch.user_id = $1
       WHERE u.id != $1
         AND u.deleted_at IS NULL
         AND u.email != $2`,
      [userId, SYSTEM_USER_EMAIL],
    );

    for (const match of matches) {
      if (match.avatar_url) match.avatar_url = resolveMediaUrl(match.avatar_url, req);
    }

    res.json({ matches });
  }),
);

export default router;
