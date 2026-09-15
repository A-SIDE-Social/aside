import { Router } from 'express';
import { v4 as uuidv4 } from 'uuid';
import { getClient, query } from '../db/pool';
import { config } from '../config';
import { writeLimit } from '../middleware/rateLimit';
import { asyncHandler, isMutualFollow, resolvePostMedia, resolveMediaUrl, getUserSubscriptionStatus, parseBeforeCursor } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { getPresignedUploadUrl, deleteStorageObjects } from '../storage';
import { getPlanLimits, LIMITS } from '../constants';
import { notifyNewPost } from '../firebase';
import { verifyPostAccess } from '../lib/postAccess';
import { postAudiencePredicate, resolvePostAudience } from '../lib/postAudience';

const router = Router();

// POST /upload-url - Get presigned upload URL(s)
router.post(
  '/upload-url',
  asyncHandler(async (req: any, res: any) => {
    const { content_type, count = 1 } = req.body;
    if (!content_type) throw new AppError(400, 'content_type is required');
    if (count < 1 || count > LIMITS.maxPhotosPerPost) {
      throw new AppError(400, `count must be between 1 and ${LIMITS.maxPhotosPerPost}`);
    }

    const isDev = config.nodeEnv === 'development' || config.nodeEnv === 'test';
    const uploads = [];
    for (let i = 0; i < count; i++) {
      const key = `${uuidv4()}`;
      const ext = content_type.split('/')[1] || 'bin';
      const filename = `${key}.${ext}`;

      if (isDev) {
        // In dev, uploads go to local filesystem served by the API
        // Use forwarded headers (ngrok/proxy) or fall back to direct host
        const proto = req.get('x-forwarded-proto') || req.protocol;
        const host = req.get('x-forwarded-host') || req.get('host');
        const baseUrl = `${proto}://${host}`;
        uploads.push({
          upload_url: `${baseUrl}/v1/posts/upload/${filename}`,
          key: filename,
        });
      } else {
        const upload_url = await getPresignedUploadUrl(filename, content_type);
        uploads.push({ upload_url, key: filename });
      }
    }

    res.json({ uploads });
  }),
);

// Dev upload routes are exported separately and mounted without auth (see routes/index.ts)
// This mirrors production where presigned S3 URLs don't require auth headers.

// POST / - Create a post
router.post(
  '/',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { caption, media, group_ids, hide_after_24h } = req.body;

    // Type-check caption FIRST. The downstream "must have caption or media"
    // guard calls `caption.trim()`, which throws a TypeError on non-strings
    // (e.g. a number) and surfaces as a 500 instead of the intended 400.
    if (caption !== undefined && caption !== null && typeof caption !== 'string') {
      throw new AppError(400, 'caption must be a string');
    }

    // Posts can be text-only (no media) or have up to maxPhotosPerPost media items
    if ((!media || media.length === 0) && (!caption || !caption.trim())) {
      throw new AppError(400, 'Post must have either a caption or media');
    }

    if (media && media.length > LIMITS.maxPhotosPerPost) {
      throw new AppError(400, `Maximum ${LIMITS.maxPhotosPerPost} media items per post`);
    }

    if (caption && caption.length > LIMITS.maxCaptionLength) {
      throw new AppError(400, `Caption must be ${LIMITS.maxCaptionLength} characters or fewer`);
    }

    // Audience validation and every relational insert happen in one
    // transaction. A malformed/stale list selection can never leave behind
    // a partially-created post that defaults to all connections.
    const client = await getClient();
    let post: any;
    let postMedia: any[] = [];
    try {
      await client.query('BEGIN');
      const audience = await resolvePostAudience(client, userId, group_ids);
      const expiresAt = hide_after_24h ? "NOW() + INTERVAL '24 hours'" : 'NULL';
      const { rows: posts } = await client.query(
        `INSERT INTO posts (user_id, caption, expires_at, audience_type)
         VALUES ($1, $2, ${expiresAt}, $3)
         RETURNING *`,
        [userId, caption || null, audience.type],
      );
      post = posts[0];

      // Create post_media records. `thumbnail_url` is the key of a
      // first-frame JPEG extracted client-side and uploaded alongside the
      // video. Photos leave it null.
      for (const item of (media || [])) {
        await client.query(
          `INSERT INTO post_media
             (post_id, media_url, media_type, width, height, position, thumbnail_url)
           VALUES ($1, $2, $3, $4, $5, $6, $7)`,
          [
            post.id,
            item.key,
            item.media_type,
            item.width || null,
            item.height || null,
            item.position,
            item.thumbnail_key || null,
          ],
        );
      }

      if (audience.type === 'lists') {
        await client.query(
          `INSERT INTO post_groups (post_id, group_id)
           SELECT $1, unnest($2::uuid[])`,
          [post.id, audience.listIds],
        );
        await client.query(
          `INSERT INTO post_audience_members (post_id, user_id)
           SELECT $1, unnest($2::uuid[])`,
          [post.id, audience.memberIds],
        );
      }

      const mediaResult = await client.query(
        'SELECT * FROM post_media WHERE post_id = $1 ORDER BY position ASC',
        [post.id],
      );
      postMedia = mediaResult.rows;
      post.audience_member_count = audience.memberIds.length;
      await client.query('COMMIT');
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }

    post.media = postMedia;
    resolvePostMedia([post], req);

    res.status(201).json({ post });

    // Fire-and-forget: notify only people allowed by the post's immutable
    // audience snapshot. notifyNewPost performs the authoritative query.
    const { rows: posterRows } = await query(
      'SELECT display_name FROM users WHERE id = $1',
      [userId],
    );
    const posterName = posterRows[0]?.display_name || 'Someone';
    const firstImageUrl = postMedia.length > 0 ? postMedia[0].media_url : undefined;
    const mediaTypes = postMedia.map((m: any) => m.media_type as string);
    notifyNewPost(
      userId,
      posterName,
      caption || null,
      post.id,
      mediaTypes,
      firstImageUrl,
    ).catch(() => {});
  }),
);

// POST /:id/like - Like a post (idempotent)
router.post(
  '/:id/like',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const postId = req.params.id;

    await verifyPostAccess(postId, userId);

    await query(
      `INSERT INTO post_likes (post_id, user_id) VALUES ($1, $2)
       ON CONFLICT (post_id, user_id) DO NOTHING`,
      [postId, userId],
    );

    const { rows: counts } = await query(
      'SELECT COUNT(*)::int AS like_count FROM post_likes WHERE post_id = $1',
      [postId],
    );

    res.json({ liked: true, like_count: counts[0].like_count });
  }),
);

// DELETE /:id/like - Unlike a post
router.delete(
  '/:id/like',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const postId = req.params.id;

    await verifyPostAccess(postId, userId);

    await query(
      'DELETE FROM post_likes WHERE post_id = $1 AND user_id = $2',
      [postId, userId],
    );

    const { rows: counts } = await query(
      'SELECT COUNT(*)::int AS like_count FROM post_likes WHERE post_id = $1',
      [postId],
    );

    res.json({ liked: false, like_count: counts[0].like_count });
  }),
);

// GET /:id/likes — list of users who liked this post (build 39).
//
// Powers the long-press-on-heart "Liked by" sheet in the mobile
// client. Access mirrors the rest of the post API: caller must be
// the post owner or a mutual follow of the post owner. Anyone in
// the network can see who liked a post they themselves can see —
// consistent with how comments are surfaced.
//
// Ordered most-recent-first so newer likes float to the top of
// the sheet (the same direction the comments list reads).
router.get(
  '/:id/likes',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const postId = req.params.id;

    await verifyPostAccess(postId, userId);

    const { rows } = await query(
      `SELECT u.id, u.display_name, u.avatar_url
       FROM post_likes pl
       JOIN users u ON u.id = pl.user_id
       WHERE pl.post_id = $1
         AND u.deleted_at IS NULL
       ORDER BY pl.created_at DESC`,
      [postId],
    );
    for (const r of rows) {
      if (r.avatar_url) r.avatar_url = resolveMediaUrl(r.avatar_url, req);
    }
    res.json({ likes: rows });
  }),
);

// GET /:id - Get post by ID
router.get(
  '/:id',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    await verifyPostAccess(id, userId);

    const { rows: posts } = await query(
      `SELECT p.*, u.username, u.display_name, u.avatar_url
       FROM posts p
       JOIN users u ON u.id = p.user_id
       WHERE p.id = $1 AND p.deleted_at IS NULL
         AND (p.expires_at IS NULL OR p.expires_at > NOW() OR p.user_id = $2)`,
      [id, userId],
    );
    if (posts.length === 0) throw new AppError(404, 'Post not found');

    const post = posts[0];
    if (post.avatar_url) post.avatar_url = resolveMediaUrl(post.avatar_url, req);

    // Fetch media
    const { rows: media } = await query(
      'SELECT * FROM post_media WHERE post_id = $1 ORDER BY position ASC',
      [id],
    );
    post.media = media;
    resolvePostMedia([post], req);

    // Like enrichment
    const { rows: likeCounts } = await query(
      'SELECT COUNT(*)::int AS like_count FROM post_likes WHERE post_id = $1',
      [id],
    );
    post.like_count = likeCounts[0].like_count;
    const { rows: userLike } = await query(
      'SELECT 1 FROM post_likes WHERE post_id = $1 AND user_id = $2',
      [id, userId],
    );
    post.is_liked = userLike.length > 0;

    // Reaction enrichment — same shape as the feed enrichment.
    // Defensive try/catch so a missing migration degrades to empty
    // reactions instead of 500-ing the whole detail fetch.
    post.reactions = [];
    try {
      const { rows: reactionRows } = await query(
        `SELECT emoji,
                COUNT(*)::int AS count,
                BOOL_OR(user_id = $2) AS reacted_by_me
           FROM post_reactions
          WHERE post_id = $1
          GROUP BY emoji
          ORDER BY count DESC, emoji ASC`,
        [id, userId],
      );
      post.reactions = reactionRows.map((r: any) => ({
        emoji: r.emoji,
        count: r.count,
        reacted_by_me: r.reacted_by_me,
      }));
    } catch (err: any) {
      if (
        err?.code !== '42P01' &&
        !/relation .* does not exist/i.test(err?.message ?? '')
      ) {
        throw err;
      }
    }

    res.json({ post });
  }),
);

// PATCH /:id - Edit own post caption
router.patch(
  '/:id',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const { caption } = req.body;

    if (caption !== undefined && caption !== null && typeof caption !== 'string') {
      throw new AppError(400, 'caption must be a string');
    }
    if (caption && caption.length > LIMITS.maxCaptionLength) {
      throw new AppError(400, `Caption must be ${LIMITS.maxCaptionLength} characters or fewer`);
    }

    const { rows, rowCount } = await query(
      `UPDATE posts SET caption = $1, updated_at = NOW()
       WHERE id = $2 AND user_id = $3 AND deleted_at IS NULL
       RETURNING *`,
      [caption || null, id, userId],
    );
    if (rowCount === 0) throw new AppError(404, 'Post not found');

    const post = rows[0];

    // Fetch media
    const { rows: media } = await query(
      'SELECT * FROM post_media WHERE post_id = $1 ORDER BY position ASC',
      [id],
    );
    post.media = media;
    resolvePostMedia([post], req);

    // Attach user info
    const { rows: users } = await query(
      'SELECT username, display_name, avatar_url FROM users WHERE id = $1',
      [userId],
    );
    if (users.length > 0) {
      post.username = users[0].username;
      post.display_name = users[0].display_name;
      post.avatar_url = users[0].avatar_url ? resolveMediaUrl(users[0].avatar_url, req) : null;
    }

    res.json({ post });
  }),
);

// DELETE /:id - Hard-delete own post and its media from storage
router.delete(
  '/:id',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    // Verify ownership
    const { rows: posts } = await query(
      'SELECT id FROM posts WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL',
      [id, userId],
    );
    if (posts.length === 0) throw new AppError(404, 'Post not found');

    // Get media keys before deleting
    const { rows: media } = await query(
      'SELECT media_url FROM post_media WHERE post_id = $1',
      [id],
    );
    const keys = media.map((m: any) => m.media_url).filter((k: string) => k && !k.startsWith('http'));

    // Delete DB records (post_media and post_groups cascade, comments
    // and notifications don't). Cleaning notifications here prevents
    // users from tapping a stale push and landing on a 404 — both for
    // the deleted post itself and for any comments on that post (since
    // those comments are about to disappear too).
    const { rows: commentRows } = await query(
      'SELECT id FROM comments WHERE post_id = $1',
      [id],
    );
    const commentIds = commentRows.map((r: any) => r.id);
    await query('DELETE FROM comments WHERE post_id = $1', [id]);
    await query(
      `DELETE FROM notifications
        WHERE (reference_type = 'post' AND reference_id = $1)
           OR (reference_type = 'comment' AND reference_id = ANY($2::uuid[]))`,
      [id, commentIds],
    );
    await query('DELETE FROM posts WHERE id = $1', [id]);

    // Delete files from storage
    if (keys.length > 0) {
      try {
        await deleteStorageObjects(keys);
      } catch (err) {
        console.warn('Failed to delete storage objects:', err);
      }
    }

    res.json({ message: 'Post deleted' });
  }),
);

// GET /by-user/:id - Get posts by a user
router.get(
  '/by-user/:id',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const targetUserId = req.params.id;
    const before = parseBeforeCursor(req.query.before);

    // Must be mutual follow (unless viewing own posts)
    if (targetUserId !== userId) {
      const mutual = await isMutualFollow(userId, targetUserId);
      if (!mutual) throw new AppError(404, 'User not found');
    }

    const subStatus = await getUserSubscriptionStatus(userId);
    const { feedHistoryDays } = getPlanLimits(subStatus);

    // A user viewing their OWN profile always sees their full history,
    // regardless of subscription plan. The history gate is about what
    // the PLATFORM shows you for free from the wider network — it
    // should never hide your own content from you. Profile grid only;
    // the main feed stays plan-gated.
    const effectiveHistoryDays =
      targetUserId === userId ? null : feedHistoryDays;

    const { rows: posts } = await query(
      `SELECT p.*, u.username, u.display_name, u.avatar_url
       FROM posts p
       JOIN users u ON u.id = p.user_id
       WHERE p.user_id = $1
         AND p.deleted_at IS NULL
         AND (p.user_id = $2 OR p.expires_at IS NULL OR p.expires_at > NOW())
         AND ${postAudiencePredicate('p', '$2')}
         AND ($3::timestamptz IS NULL OR p.created_at < $3)
         AND ($4::int IS NULL OR p.created_at > NOW() - make_interval(days => $4))
       ORDER BY p.created_at DESC LIMIT ${LIMITS.postsPerPage}`,
      [targetUserId, userId, before, effectiveHistoryDays],
    );

    // Fetch media for all posts
    if (posts.length > 0) {
      const postIds = posts.map((p: any) => p.id);
      const { rows: media } = await query(
        'SELECT * FROM post_media WHERE post_id = ANY($1) ORDER BY position ASC',
        [postIds],
      );

      const mediaByPost = new Map<string, any[]>();
      for (const m of media) {
        if (!mediaByPost.has(m.post_id)) mediaByPost.set(m.post_id, []);
        mediaByPost.get(m.post_id)!.push(m);
      }

      // Like enrichment
      const { rows: likeCounts } = await query(
        `SELECT post_id, COUNT(*)::int AS like_count
         FROM post_likes WHERE post_id = ANY($1) GROUP BY post_id`,
        [postIds],
      );
      const likeCountByPost = new Map<string, number>();
      for (const lc of likeCounts) likeCountByPost.set(lc.post_id, lc.like_count);

      const { rows: userLikes } = await query(
        'SELECT post_id FROM post_likes WHERE post_id = ANY($1) AND user_id = $2',
        [postIds, userId],
      );
      const likedByUser = new Set(userLikes.map((l: any) => l.post_id));

      for (const post of posts) {
        post.media = mediaByPost.get(post.id) || [];
        post.like_count = likeCountByPost.get(post.id) || 0;
        post.is_liked = likedByUser.has(post.id);
      }
    }

    for (const post of posts) {
      if (post.avatar_url) post.avatar_url = resolveMediaUrl(post.avatar_url, req);
    }
    resolvePostMedia(posts, req);
    res.json({ posts });
  }),
);

export default router;
