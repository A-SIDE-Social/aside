import { Router } from 'express';
import { query } from '../db/pool';
import { authenticate } from '../middleware/auth';
import { writeLimit, regenerateLimit } from '../middleware/rateLimit';
import { asyncHandler, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { SYSTEM_USER_EMAIL } from '../constants';
import { config } from '../config';
import {
  sendPush,
  getTokensForUsers,
  filterByPushThrottle,
  stampPushSent,
} from '../firebase';
import {
  SLUG_REGEX,
  generateUniqueSlug,
  extractSlug,
} from '../lib/slugs';

const router = Router();

function buildInviteUrl(slug: string): string {
  return `${config.inviteLinkHost}/${slug}`;
}

// Helper: shape the response a `GET /v1/invite-link` (and regenerate)
// returns. Keeps the JSON contract in one place so the mobile client
// has a single source of truth.
function inviteLinkPayload(slug: string) {
  return { slug, url: buildInviteUrl(slug) };
}

// GET /v1/invite-link — return the caller's current invite slug + URL.
//
// Defensive fallback: if the user somehow has a NULL `invite_slug`
// (shouldn't be possible post-migration, but a row inserted before
// the NOT NULL flip would lack one), generate one on the fly. The
// migration is the canonical backfill but this guard means the
// endpoint never returns a broken state.
router.get(
  '/',
  authenticate,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { rows } = await query(
      'SELECT invite_slug FROM users WHERE id = $1 AND deleted_at IS NULL',
      [userId],
    );
    if (rows.length === 0) throw new AppError(404, 'User not found');

    let slug: string = rows[0].invite_slug;
    if (!slug) {
      slug = await generateUniqueSlug(async (candidate) => {
        const { rows: existing } = await query(
          'SELECT 1 FROM users WHERE LOWER(invite_slug) = LOWER($1)',
          [candidate],
        );
        return existing.length > 0;
      });
      await query('UPDATE users SET invite_slug = $1 WHERE id = $2', [slug, userId]);
    }
    res.json(inviteLinkPayload(slug));
  }),
);

// POST /v1/invite-link/regenerate — rotate the caller's slug.
//
// Old slug becomes invalid (lookup returns 404). New slug becomes the
// only working one. This is the recovery path for "I accidentally
// posted my QR publicly" or "I want to revoke an ex's access."
//
// Rate-limited via regenerateLimit (10/day per user) — well above
// the legitimate event rate, well below "someone is grieving pending
// recipients by churning slugs."
router.post(
  '/regenerate',
  authenticate,
  regenerateLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const slug = await generateUniqueSlug(async (candidate) => {
      const { rows: existing } = await query(
        'SELECT 1 FROM users WHERE LOWER(invite_slug) = LOWER($1)',
        [candidate],
      );
      return existing.length > 0;
    });
    const { rowCount } = await query(
      `UPDATE users
       SET invite_slug = $1,
           invite_slug_rotated_at = NOW()
       WHERE id = $2 AND deleted_at IS NULL`,
      [slug, userId],
    );
    if (rowCount === 0) throw new AppError(404, 'User not found');
    res.json(inviteLinkPayload(slug));
  }),
);

// POST /v1/invite-link/request — send a follow request via someone
// else's invite slug.
//
// Atomic lookup + follow-create. Body accepts either `slug` or `url`
// (mobile/web call sites have both). Returns one of:
//   - { status: 'requested' }       — new one-way follow was created
//   - { status: 'already_following' } — caller was already following
//   - { status: 'already_mutual' }    — pair was already mutual
//   - { status: 'self' }              — slug belongs to caller (no-op)
//   - 400 / 404 on malformed / unknown / deleted / system slugs
//
// The "self" case is a silent no-op rather than an error so the mobile
// client's signup-via-link flow can call it unconditionally without
// special-casing (a user who installed via their own link — possible
// in dev / via a friend re-sharing — just gets nothing).
//
// On a fresh inbound follow, fires the same `inbound_follow`
// notification as POST /v1/follows so the recipient's existing
// InboundFollowsScreen and push channel handle it without changes.
router.post(
  '/request',
  authenticate,
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const callerId = req.user!.userId;
    const rawInput = (req.body?.slug ?? req.body?.url ?? '').toString().trim();
    if (!rawInput) throw new AppError(400, 'slug is required');

    const slug = extractSlug(rawInput, config.inviteLinkAllowedHosts);
    if (!slug) throw new AppError(400, 'Invalid invite link format');

    // Resolve slug → user. Reject deleted accounts and the system
    // sentinel user (placeholder owner for the dev invite — never
    // reachable via this surface).
    const { rows: target } = await query(
      `SELECT id, display_name
       FROM users
       WHERE LOWER(invite_slug) = LOWER($1)
         AND deleted_at IS NULL
         AND email != $2`,
      [slug, SYSTEM_USER_EMAIL],
    );
    if (target.length === 0) throw new AppError(404, 'Invite link not found');

    const targetUserId = target[0].id;

    // Self-add is silent no-op (see header comment for rationale).
    if (targetUserId === callerId) {
      res.json({ status: 'self' });
      return;
    }

    // Idempotent insert. Same pattern as POST /v1/follows so a
    // double-tap from the send-request screen doesn't re-fire the
    // notification.
    const { rows: inserted } = await query(
      `INSERT INTO follows (follower_id, followee_id)
       VALUES ($1, $2)
       ON CONFLICT (follower_id, followee_id) DO NOTHING
       RETURNING id`,
      [callerId, targetUserId],
    );
    const isNew = inserted.length > 0;

    // Is the reverse follow already in place? (e.g. the target user
    // already requested the caller — accepting via slug instead of
    // tapping the inbound-follows UI is fine.)
    const { rows: reverse } = await query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [targetUserId, callerId],
    );
    const isMutual = reverse.length > 0;

    if (!isNew) {
      res.json({
        status: isMutual ? 'already_mutual' : 'already_following',
      });
      return;
    }

    // Newly-created follow. Fire the appropriate notification.
    const { rows: callerInfo } = await query(
      'SELECT display_name FROM users WHERE id = $1',
      [callerId],
    );
    const callerName = callerInfo[0]?.display_name || 'Someone';

    if (isMutual) {
      // Symmetric notification + push to both sides.
      await query(
        `INSERT INTO notifications (user_id, type, actor_id, reference_type)
         VALUES ($1, 'new_mutual', $2, 'follow'), ($2, 'new_mutual', $1, 'follow')`,
        [callerId, targetUserId],
      );
      const { rows: prefRows } = await query(
        'SELECT COALESCE((SELECT connections FROM notification_preferences WHERE user_id = $1), true) AS enabled',
        [targetUserId],
      );
      if (prefRows[0].enabled) {
        const allowed = await filterByPushThrottle([targetUserId]);
        if (allowed.length > 0) {
          const tokens = await getTokensForUsers([targetUserId]);
          if (tokens.length > 0) {
            await sendPush(tokens, 'New Connection', `You and ${callerName} are now connected`, {
              type: 'new_mutual',
              user_id: callerId,
            });
            await stampPushSent([targetUserId]);
          }
        }
      }
      res.status(201).json({ status: 'already_mutual' });
      return;
    }

    // One-way request. Same notification shape as POST /v1/follows so
    // the inbound surface treats it identically.
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type)
       VALUES ($1, 'inbound_follow', $2, 'follow')`,
      [targetUserId, callerId],
    );
    const { rows: prefRows } = await query(
      'SELECT COALESCE((SELECT connections FROM notification_preferences WHERE user_id = $1), true) AS enabled',
      [targetUserId],
    );
    if (prefRows[0].enabled) {
      const allowed = await filterByPushThrottle([targetUserId]);
      if (allowed.length > 0) {
        const tokens = await getTokensForUsers([targetUserId]);
        if (tokens.length > 0) {
          await sendPush(tokens, 'Connection Request', `${callerName} wants to connect with you`, {
            type: 'inbound_follow',
            user_id: callerId,
          });
          await stampPushSent([targetUserId]);
        }
      }
    }

    res.status(201).json({ status: 'requested' });
  }),
);

export default router;
