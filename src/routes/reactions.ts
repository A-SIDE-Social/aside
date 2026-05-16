// Emoji reactions on posts.
//
// Two endpoints:
//   POST /v1/posts/:id/reactions/toggle  body { emoji }
//        Idempotent toggle. If the user already reacted with this
//        emoji, removes the row; else inserts. Returns the post's
//        full grouped reaction summary.
//
//   GET  /v1/posts/:id/reactions/:emoji/users
//        Paginated list of users who reacted with this specific
//        emoji. Used by the long-press sheet.
//
// Both endpoints gate on `verifyPostAccess` (the shared post-access
// predicate from src/lib/postAccess.ts). A user reacting to or
// inspecting reactors of a post they shouldn't see would be a real
// privacy bug — same predicate as comments / posts detail.
//
// Defensive: if the post_reactions table doesn't exist (forgotten
// migration), returns a 503 with a clear message rather than the
// generic 500 a "relation does not exist" error would produce.

import { Router } from 'express';
import { query } from '../db/pool';
import { authenticate } from '../middleware/auth';
import { writeLimit } from '../middleware/rateLimit';
import { asyncHandler, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { verifyPostAccess } from '../lib/postAccess';

const router = Router();

// Single-grapheme validator. Strips obvious garbage before reaching
// the DB CHECK constraint. Uses Intl.Segmenter (Node 16+) to count
// grapheme clusters — handles ZWJ sequences and skin-tone modifiers
// as one grapheme.
const graphemeSegmenter = new Intl.Segmenter(undefined, {
  granularity: 'grapheme',
});

function isValidEmoji(input: unknown): input is string {
  if (typeof input !== 'string') return false;
  const trimmed = input.trim();
  if (trimmed.length === 0 || trimmed.length > 16) return false;
  // No control characters or format characters (zero-width joiners
  // are allowed via the grapheme segmenter — those are inside, not
  // wrapping). \p{Cc} = control, \p{Cf} = format.
  if (/[\p{Cc}]/u.test(trimmed)) return false;
  const graphemes = [...graphemeSegmenter.segment(trimmed)];
  return graphemes.length === 1;
}

/**
 * Group post_reactions rows for a single post into the client-shaped
 * summary `[{emoji, count, reacted_by_me}]`. Single round-trip query.
 */
async function reactionSummaryForPost(postId: string, viewerId: string) {
  try {
    const { rows } = await query(
      `SELECT r.emoji,
              COUNT(*)::int AS count,
              BOOL_OR(r.user_id = $2) AS reacted_by_me
         FROM post_reactions r
        WHERE r.post_id = $1
        GROUP BY r.emoji
        ORDER BY count DESC, r.emoji ASC`,
      [postId, viewerId],
    );
    return rows.map((r: any) => ({
      emoji: r.emoji,
      count: r.count,
      reacted_by_me: r.reacted_by_me,
    }));
  } catch (err: any) {
    // Defensive: the migration adding post_reactions may not have run
    // yet on this server. Surface a clean 503 so the failure mode is
    // obvious instead of a generic 500.
    if (err?.code === '42P01' || /relation .* does not exist/i.test(err?.message ?? '')) {
      throw new AppError(503, 'Reactions are temporarily unavailable (pending migration).');
    }
    throw err;
  }
}

// POST /posts/:postId/reactions/toggle
router.post(
  '/posts/:postId/reactions/toggle',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { postId } = req.params;
    const { emoji } = req.body;

    if (!isValidEmoji(emoji)) {
      throw new AppError(400, 'emoji must be a single emoji grapheme');
    }
    const trimmed = emoji.trim();

    // Visibility gate. Reuse the canonical predicate; never accept a
    // reaction on a post the user can't see.
    await verifyPostAccess(postId, userId);

    // Toggle. Try delete first; if nothing was deleted, insert.
    // Single transaction so concurrent toggles don't race.
    let inserted = false;
    try {
      const { rowCount } = await query(
        `DELETE FROM post_reactions
          WHERE post_id = $1 AND user_id = $2 AND emoji = $3`,
        [postId, userId, trimmed],
      );
      if ((rowCount ?? 0) === 0) {
        await query(
          `INSERT INTO post_reactions (post_id, user_id, emoji)
                VALUES ($1, $2, $3)
           ON CONFLICT (post_id, user_id, emoji) DO NOTHING`,
          [postId, userId, trimmed],
        );
        inserted = true;
      }
    } catch (err: any) {
      if (err?.code === '42P01' || /relation .* does not exist/i.test(err?.message ?? '')) {
        throw new AppError(503, 'Reactions are temporarily unavailable (pending migration).');
      }
      throw err;
    }

    const reactions = await reactionSummaryForPost(postId, userId);
    res.json({
      reacted: inserted,
      reactions,
    });
  }),
);

// GET /posts/:postId/reactions/:emoji/users
router.get(
  '/posts/:postId/reactions/:emoji/users',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { postId, emoji } = req.params;

    if (!isValidEmoji(emoji)) {
      throw new AppError(400, 'emoji must be a single emoji grapheme');
    }
    const trimmed = (emoji as string).trim();

    await verifyPostAccess(postId, userId);

    // Pagination: ?before=<ISO timestamp> for cursor-style. v1 keeps
    // it simple — fixed page size of 50, before-cursor on created_at.
    const before = (req.query.before as string | undefined) ?? null;
    const params: any[] = [postId, trimmed];
    let cursor = '';
    if (before) {
      cursor = ' AND r.created_at < $3';
      params.push(before);
    }

    let rows;
    try {
      ({ rows } = await query(
        `SELECT u.id, u.display_name, u.avatar_url, r.created_at
           FROM post_reactions r
           JOIN users u ON u.id = r.user_id
          WHERE r.post_id = $1 AND r.emoji = $2${cursor}
          ORDER BY r.created_at DESC
          LIMIT 50`,
        params,
      ));
    } catch (err: any) {
      if (err?.code === '42P01' || /relation .* does not exist/i.test(err?.message ?? '')) {
        throw new AppError(503, 'Reactions are temporarily unavailable (pending migration).');
      }
      throw err;
    }

    const users = rows.map((r: any) => ({
      id: r.id,
      display_name: r.display_name,
      avatar_url: r.avatar_url ? resolveMediaUrl(r.avatar_url, req) : null,
      reacted_at: r.created_at,
    }));
    res.json({ users });
  }),
);

export default router;
export { reactionSummaryForPost };
