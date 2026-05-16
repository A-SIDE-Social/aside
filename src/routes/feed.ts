import { Router } from 'express';
import { query } from '../db/pool';
import { asyncHandler, resolvePostMedia, resolveMediaUrl, getUserSubscriptionStatus, parseBeforeCursor } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { getPlanLimits, LIMITS } from '../constants';

const router = Router();

// GET / - Chronological feed from mutual follows
router.get(
  '/',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const before = parseBeforeCursor(req.query.before);
    const groupId = (req.query.group_id as string) || null;
    const excludeOwn = req.query.exclude_own === 'true';
    const limit = Math.min(Math.max(parseInt(req.query.limit as string) || LIMITS.postsPerPage, 1), LIMITS.postsPerPage);

    const status = await getUserSubscriptionStatus(userId);
    const { feedHistoryDays } = getPlanLimits(status);

    let posts;

    if (groupId) {
      // Verify the group belongs to the current user
      const { rows: groups } = await query(
        'SELECT id FROM groups WHERE id = $1 AND user_id = $2',
        [groupId, userId],
      );
      if (groups.length === 0) throw new AppError(404, 'Group not found');

      const { rows } = await query(
        `SELECT p.*, u.username, u.display_name, u.avatar_url
         FROM posts p
         JOIN users u ON u.id = p.user_id
         JOIN group_members gm ON gm.member_user_id = p.user_id AND gm.group_id = $2
         WHERE p.deleted_at IS NULL
         AND (p.expires_at IS NULL OR p.expires_at > NOW())
         AND (
           p.user_id = $1
           OR p.user_id IN (
             SELECT f1.followee_id FROM follows f1
             JOIN follows f2 ON f2.follower_id = f1.followee_id AND f2.followee_id = f1.follower_id
             WHERE f1.follower_id = $1
           )
         )
         AND ($3::timestamptz IS NULL OR p.created_at < $3)
         AND ($4::int IS NULL OR p.created_at > NOW() - make_interval(days => $4))
         AND ($5::boolean IS NOT TRUE OR p.user_id != $1)
         ORDER BY p.created_at DESC LIMIT ${limit}`,
        [userId, groupId, before, feedHistoryDays, excludeOwn],
      );
      posts = rows;
    } else {
      const { rows } = await query(
        `SELECT p.*, u.username, u.display_name, u.avatar_url
         FROM posts p
         JOIN users u ON u.id = p.user_id
         WHERE (
           p.user_id = $1
           OR p.user_id IN (
             SELECT f1.followee_id FROM follows f1
             JOIN follows f2 ON f2.follower_id = f1.followee_id AND f2.followee_id = f1.follower_id
             WHERE f1.follower_id = $1
           )
         )
         AND p.deleted_at IS NULL
         AND (p.expires_at IS NULL OR p.expires_at > NOW())
         AND (
           NOT EXISTS (SELECT 1 FROM post_groups pg WHERE pg.post_id = p.id)
           OR EXISTS (
             SELECT 1 FROM post_groups pg
             JOIN group_members gm ON gm.group_id = pg.group_id
             WHERE pg.post_id = p.id AND gm.member_user_id = $1
           )
         )
         AND ($2::timestamptz IS NULL OR p.created_at < $2)
         AND ($3::int IS NULL OR p.created_at > NOW() - make_interval(days => $3))
         AND ($4::boolean IS NOT TRUE OR p.user_id != $1)
         ORDER BY p.created_at DESC LIMIT ${limit}`,
        [userId, before, feedHistoryDays, excludeOwn],
      );
      posts = rows;
    }

    // Fetch media for all posts
    if (posts.length > 0) {
      const postIds = posts.map((p: any) => p.id);
      const { rows: media } = await query(
        `SELECT * FROM post_media WHERE post_id = ANY($1) ORDER BY position ASC`,
        [postIds],
      );

      const mediaByPost = new Map<string, any[]>();
      for (const m of media) {
        if (!mediaByPost.has(m.post_id)) mediaByPost.set(m.post_id, []);
        mediaByPost.get(m.post_id)!.push(m);
      }

      // Fetch comment counts and recent comments (latest 2). Both
      // queries strip deleted comments AND replies whose parent is
      // deleted, so the badge count matches what the comments sheet
      // actually renders (the sheet uses the same filter — see
      // src/routes/comments.ts).
      const { rows: commentCounts } = await query(
        `SELECT c.post_id, COUNT(*)::int AS comment_count
         FROM comments c
         LEFT JOIN comments parent_c ON parent_c.id = c.reply_to_comment_id
         WHERE c.post_id = ANY($1)
           AND c.deleted_at IS NULL
           AND (c.reply_to_comment_id IS NULL OR parent_c.deleted_at IS NULL)
         GROUP BY c.post_id`,
        [postIds],
      );
      const countByPost = new Map<string, number>();
      for (const c of commentCounts) {
        countByPost.set(c.post_id, c.comment_count);
      }

      const { rows: recentComments } = await query(
        `SELECT DISTINCT ON (c.post_id, c.id)
           c.id, c.post_id, c.user_id, c.body, c.created_at,
           u.display_name, u.avatar_url
         FROM comments c
         JOIN users u ON u.id = c.user_id
         LEFT JOIN comments parent_c ON parent_c.id = c.reply_to_comment_id
         WHERE c.post_id = ANY($1)
           AND c.deleted_at IS NULL
           AND (c.reply_to_comment_id IS NULL OR parent_c.deleted_at IS NULL)
         AND c.id IN (
           SELECT id FROM (
             SELECT inner_c.id, inner_c.post_id,
                    ROW_NUMBER() OVER (PARTITION BY inner_c.post_id ORDER BY inner_c.created_at DESC) AS rn
             FROM comments inner_c
             LEFT JOIN comments inner_parent ON inner_parent.id = inner_c.reply_to_comment_id
             WHERE inner_c.post_id = ANY($1)
               AND inner_c.deleted_at IS NULL
               AND (inner_c.reply_to_comment_id IS NULL OR inner_parent.deleted_at IS NULL)
           ) sub WHERE rn <= 2
         )
         ORDER BY c.post_id, c.id, c.created_at ASC`,
        [postIds],
      );
      const commentsByPost = new Map<string, any[]>();
      for (const c of recentComments) {
        if (c.avatar_url) c.avatar_url = resolveMediaUrl(c.avatar_url, req);
        if (!commentsByPost.has(c.post_id)) commentsByPost.set(c.post_id, []);
        commentsByPost.get(c.post_id)!.push(c);
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

      // Reaction enrichment. One query gets {post_id, emoji, count,
      // reacted_by_me} for the entire page. Defensive try/catch so
      // the feed degrades gracefully (empty reactions per post)
      // rather than 500-ing if the post_reactions migration hasn't
      // been applied yet on this server.
      const reactionsByPost = new Map<string, any[]>();
      try {
        const { rows: reactionRows } = await query(
          `SELECT post_id, emoji,
                  COUNT(*)::int AS count,
                  BOOL_OR(user_id = $2) AS reacted_by_me
             FROM post_reactions
            WHERE post_id = ANY($1)
            GROUP BY post_id, emoji
            ORDER BY post_id, count DESC, emoji ASC`,
          [postIds, userId],
        );
        for (const r of reactionRows) {
          if (!reactionsByPost.has(r.post_id)) {
            reactionsByPost.set(r.post_id, []);
          }
          reactionsByPost.get(r.post_id)!.push({
            emoji: r.emoji,
            count: r.count,
            reacted_by_me: r.reacted_by_me,
          });
        }
      } catch (err: any) {
        if (
          err?.code !== '42P01' &&
          !/relation .* does not exist/i.test(err?.message ?? '')
        ) {
          throw err;
        }
        // Pending migration — leave reactionsByPost empty; every
        // post will surface `reactions: []` to the client.
      }

      for (const post of posts) {
        post.media = mediaByPost.get(post.id) || [];
        post.comment_count = countByPost.get(post.id) || 0;
        post.recent_comments = commentsByPost.get(post.id) || [];
        post.like_count = likeCountByPost.get(post.id) || 0;
        post.is_liked = likedByUser.has(post.id);
        post.reactions = reactionsByPost.get(post.id) || [];
      }
    }

    for (const post of posts) {
      if (post.avatar_url) post.avatar_url = resolveMediaUrl(post.avatar_url, req);
    }
    resolvePostMedia(posts, req);

    // Does the user have older posts from their network that are
    // hidden behind the plan gate? Mirrors has_older_messages on the
    // conversations endpoint. When true, the mobile feed shows the
    // paywall banner at the end of the list; when false, there are
    // no older posts to upsell and the banner is suppressed.
    //
    // Only runs when the plan gate is active (feedHistoryDays != null)
    // AND the request isn't cursor-paginated (before=null): the flag
    // describes "are there older posts I could see with Pro?" which
    // only makes sense at the end of the visible window. Subsequent
    // pages inherit the original answer client-side.
    //
    // For group-filtered views we use the unfiltered network set for
    // the check — if there exist older posts from connections at all,
    // we surface the banner even if they happen to be outside the
    // currently selected list. Correct enough for the upsell signal.
    let hasOlderPosts = false;
    if (feedHistoryDays != null && before === null) {
      const { rows: olderCheck } = await query(
        `SELECT EXISTS (
           SELECT 1 FROM posts p
           WHERE p.deleted_at IS NULL
             AND (p.expires_at IS NULL OR p.expires_at > NOW())
             AND p.created_at <= NOW() - make_interval(days => $2)
             AND (
               p.user_id = $1
               OR p.user_id IN (
                 SELECT f1.followee_id FROM follows f1
                 JOIN follows f2 ON f2.follower_id = f1.followee_id AND f2.followee_id = f1.follower_id
                 WHERE f1.follower_id = $1
               )
             )
             AND (
               NOT EXISTS (SELECT 1 FROM post_groups pg WHERE pg.post_id = p.id)
               OR EXISTS (
                 SELECT 1 FROM post_groups pg
                 JOIN group_members gm ON gm.group_id = pg.group_id
                 WHERE pg.post_id = p.id AND gm.member_user_id = $1
               )
             )
         ) AS has_older`,
        [userId, feedHistoryDays],
      );
      hasOlderPosts = olderCheck[0]?.has_older ?? false;
    }

    res.json({ posts, has_older_posts: hasOlderPosts });
  }),
);

export default router;
