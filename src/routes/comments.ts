import { Router } from 'express';
import { query } from '../db/pool';
import { authenticate } from '../middleware/auth';
import { writeLimit } from '../middleware/rateLimit';
import { asyncHandler, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { LIMITS } from '../constants';
import { notifyComment, notifyCommentReply } from '../firebase';
// Post-access predicate (mutual follow + group scoping). Extracted
// to src/lib/postAccess.ts so reactions, posts, and comments share
// one canonical authorization check — drift between callers would
// silently expose private posts.
import { verifyPostAccess } from '../lib/postAccess';

// UUID v4 shape. Loose enough for all gen_random_uuid() outputs.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const router = Router();

// GET /posts/:postId/comments - List comments on a post
router.get(
  '/posts/:postId/comments',
  authenticate,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { postId } = req.params;

    await verifyPostAccess(postId, userId);

    // LEFT JOIN the parent comment + parent author so the client can
    // render "@{reply_to_display_name} ..." prefixes without a second
    // round-trip. Also expose `reply_to_user_id` so the @-prefix can
    // route to the replied-to user's profile when tapped.
    // reply_to_* fields are NULL for non-reply comments.
    //
    // `like_count` and `is_liked` are the per-comment aggregates for
    // the heart button. Subqueries keep the row shape identical to
    // posts.ts (POST /posts/:id likes enrichment).
    //
    // Deleted comments and replies whose parent is deleted are filtered
    // OUT entirely — the client used to render a literal "[deleted]"
    // placeholder which was confusing visual noise. The two predicates:
    //   1. c.deleted_at IS NULL — drop the deleted comments themselves
    //   2. (c.reply_to_comment_id IS NULL OR parent_c.deleted_at IS NULL)
    //      — drop replies that reference a now-deleted parent so the
    //      thread doesn't dangle. The parent_c LEFT JOIN above already
    //      provides the lookup; we just gate on it.
    const { rows: comments } = await query(
      `SELECT c.*, u.username, u.display_name, u.avatar_url,
              parent_u.id AS reply_to_user_id,
              parent_u.display_name AS reply_to_display_name,
              (SELECT COUNT(*)::int FROM comment_likes
                 WHERE comment_id = c.id) AS like_count,
              EXISTS(SELECT 1 FROM comment_likes
                 WHERE comment_id = c.id AND user_id = $2) AS is_liked
       FROM comments c
       JOIN users u ON u.id = c.user_id
       LEFT JOIN comments parent_c ON parent_c.id = c.reply_to_comment_id
       LEFT JOIN users parent_u ON parent_u.id = parent_c.user_id
       WHERE c.post_id = $1
         AND c.deleted_at IS NULL
         AND (c.reply_to_comment_id IS NULL OR parent_c.deleted_at IS NULL)
       ORDER BY c.created_at ASC`,
      [postId, userId],
    );

    for (const comment of comments) {
      if (comment.avatar_url) comment.avatar_url = resolveMediaUrl(comment.avatar_url, req);
    }
    res.json({ comments });
  }),
);

// POST /posts/:postId/comments - Create a comment (optionally a reply)
router.post(
  '/posts/:postId/comments',
  authenticate,
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { postId } = req.params;
    const { body, reply_to_comment_id } = req.body;

    if (!body || typeof body !== 'string') throw new AppError(400, 'body is required');
    if (body.length > LIMITS.maxCommentLength) {
      throw new AppError(400, `Comment body must be ${LIMITS.maxCommentLength} characters or fewer`);
    }

    const post = await verifyPostAccess(postId, userId);

    // If this is a reply, validate the parent:
    //   - valid UUID shape
    //   - exists, belongs to the same post, not soft-deleted
    // parentUserId is used below to decide who to notify.
    let parentUserId: string | null = null;
    let replyTo: string | null = null;
    if (reply_to_comment_id != null) {
      if (typeof reply_to_comment_id !== 'string' || !UUID_RE.test(reply_to_comment_id)) {
        throw new AppError(400, 'reply_to_comment_id must be a valid UUID');
      }
      const { rows: parents } = await query(
        'SELECT user_id, post_id, deleted_at FROM comments WHERE id = $1',
        [reply_to_comment_id],
      );
      if (parents.length === 0) {
        throw new AppError(400, 'reply_to_comment_id not found');
      }
      const parent = parents[0];
      if (parent.post_id !== postId) {
        throw new AppError(400, 'reply_to_comment_id belongs to a different post');
      }
      if (parent.deleted_at) {
        throw new AppError(400, 'Cannot reply to a deleted comment');
      }
      parentUserId = parent.user_id;
      replyTo = reply_to_comment_id;
    }

    const { rows: comments } = await query(
      `INSERT INTO comments (post_id, user_id, body, reply_to_comment_id)
       VALUES ($1, $2, $3, $4) RETURNING *`,
      [postId, userId, body, replyTo],
    );
    const newComment = comments[0];

    // Compute recipient set. Each recipient gets at most one notification.
    // If a user is both post author AND parent comment author, they get
    // a single 'comment_reply' row (more specific event wins over 'comment').
    // Self (the commenter) is never notified.
    const authorIsCommenter = post.user_id === userId;
    const parentIsCommenter = parentUserId != null && parentUserId === userId;
    const samePerson = parentUserId != null && post.user_id === parentUserId;

    const recipients: { userId: string; type: 'comment' | 'comment_reply' }[] = [];
    if (parentUserId != null && !parentIsCommenter) {
      recipients.push({ userId: parentUserId, type: 'comment_reply' });
    }
    if (!authorIsCommenter && !samePerson) {
      recipients.push({ userId: post.user_id, type: 'comment' });
    }

    if (recipients.length > 0) {
      // Fetch the actor's display name once for push bodies.
      const { rows: actors } = await query(
        'SELECT display_name FROM users WHERE id = $1',
        [userId],
      );
      const actorName = actors[0]?.display_name ?? 'Someone';

      for (const r of recipients) {
        // reference points at the new comment (not the post) so future
        // deep-links can scroll to it without another migration.
        await query(
          `INSERT INTO notifications (user_id, type, actor_id, reference_id, reference_type)
           VALUES ($1, $2, $3, $4, 'comment')`,
          [r.userId, r.type, userId, newComment.id],
        );
        if (r.type === 'comment_reply') {
          notifyCommentReply(r.userId, actorName, body, postId, newComment.id).catch(() => {});
        } else {
          notifyComment(r.userId, actorName, body, postId, newComment.id).catch(() => {});
        }
      }
    }

    res.status(201).json({ comment: newComment });
  }),
);

// PUT /comments/:id - Edit own comment
router.put(
  '/comments/:id',
  authenticate,
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const { body } = req.body;

    if (!body || typeof body !== 'string') throw new AppError(400, 'body is required');
    if (body.length > LIMITS.maxCommentLength) {
      throw new AppError(400, `Comment body must be ${LIMITS.maxCommentLength} characters or fewer`);
    }

    const { rows, rowCount } = await query(
      `UPDATE comments SET body = $1, updated_at = NOW()
       WHERE id = $2 AND user_id = $3 AND deleted_at IS NULL
       RETURNING *`,
      [body, id, userId],
    );
    if (rowCount === 0) throw new AppError(404, 'Comment not found');

    // Attach user info
    const { rows: users } = await query(
      'SELECT display_name, avatar_url FROM users WHERE id = $1',
      [userId],
    );
    const comment = rows[0];
    if (users.length > 0) {
      comment.display_name = users[0].display_name;
      comment.avatar_url = users[0].avatar_url ? resolveMediaUrl(users[0].avatar_url, req) : null;
    }

    res.json({ comment });
  }),
);

// POST /comments/:id/like - Like a comment (idempotent).
// Mirrors POST /posts/:id/like — same INSERT ... ON CONFLICT DO NOTHING
// pattern, same response shape. No access check (matches post likes);
// knowing the comment id is already a reasonable proxy for access.
router.post(
  '/comments/:id/like',
  authenticate,
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    const { rows: existing } = await query(
      'SELECT id FROM comments WHERE id = $1 AND deleted_at IS NULL',
      [id],
    );
    if (existing.length === 0) throw new AppError(404, 'Comment not found');

    await query(
      `INSERT INTO comment_likes (comment_id, user_id) VALUES ($1, $2)
       ON CONFLICT (comment_id, user_id) DO NOTHING`,
      [id, userId],
    );

    const { rows: counts } = await query(
      'SELECT COUNT(*)::int AS like_count FROM comment_likes WHERE comment_id = $1',
      [id],
    );
    res.json({ liked: true, like_count: counts[0].like_count });
  }),
);

// DELETE /comments/:id/like - Unlike a comment.
router.delete(
  '/comments/:id/like',
  authenticate,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    await query(
      'DELETE FROM comment_likes WHERE comment_id = $1 AND user_id = $2',
      [id, userId],
    );

    const { rows: counts } = await query(
      'SELECT COUNT(*)::int AS like_count FROM comment_likes WHERE comment_id = $1',
      [id],
    );
    res.json({ liked: false, like_count: counts[0].like_count });
  }),
);

// GET /comments/:id/likes — list of users who liked this comment
// (build 39). Powers the long-press-on-heart "Liked by" sheet,
// same UI pattern as GET /posts/:id/likes.
//
// Access mirrors the existing POST /comments/:id/like — knowing
// the comment id is the proxy. We don't gate on the post's mutual
// follow check at this layer because the comments-list endpoint
// already enforces that upstream; if the caller has the comment
// id, they got it from a place they had access to.
router.get(
  '/comments/:id/likes',
  authenticate,
  asyncHandler(async (req: any, res: any) => {
    const { id } = req.params;

    const { rows: existing } = await query(
      'SELECT id FROM comments WHERE id = $1 AND deleted_at IS NULL',
      [id],
    );
    if (existing.length === 0) throw new AppError(404, 'Comment not found');

    const { rows } = await query(
      `SELECT u.id, u.display_name, u.avatar_url
       FROM comment_likes cl
       JOIN users u ON u.id = cl.user_id
       WHERE cl.comment_id = $1
         AND u.deleted_at IS NULL
       ORDER BY cl.created_at DESC`,
      [id],
    );
    for (const r of rows) {
      if (r.avatar_url) r.avatar_url = resolveMediaUrl(r.avatar_url, req);
    }
    res.json({ likes: rows });
  }),
);

// DELETE /comments/:id - Soft-delete own comment
router.delete(
  '/comments/:id',
  authenticate,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    const { rowCount } = await query(
      `UPDATE comments SET body = '[deleted]', deleted_at = NOW()
       WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`,
      [id, userId],
    );
    if (rowCount === 0) throw new AppError(404, 'Comment not found');

    res.json({ message: 'Comment deleted' });
  }),
);

export default router;
