import { Router } from 'express';
import { query } from '../db/pool';
import { authenticate } from '../middleware/auth';
import { writeLimit, regenerateLimit } from '../middleware/rateLimit';
import { asyncHandler } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { config } from '../config';
import { createConnection, pushConnection } from '../lib/connections';
import {
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
      const { rows: saved } = await query(
        'UPDATE users SET invite_slug = COALESCE(invite_slug, $1) WHERE id = $2 AND deleted_at IS NULL RETURNING invite_slug',
        [slug, userId],
      );
      if (!saved.length) throw new AppError(404, 'User not found');
      slug = saved[0].invite_slug;
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

    const result = await createConnection(callerId, { slug });
    await pushConnection(result);
    res.status(result.isNew ? 201 : 200).json({
      status: result.self ? 'self' : result.isMutual ? 'already_mutual'
        : result.isNew ? 'requested' : 'already_following',
    });
  }),
);

export default router;
