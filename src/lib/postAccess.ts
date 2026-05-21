// Shared post-access predicate.
//
// Originally lived as `verifyPostAccess` inside src/routes/comments.ts.
// Extracted here so reactions, comments, posts (detail), and any
// future post-content endpoints share one canonical authorization
// check. Drift between callers (e.g. comments accepts X but
// reactions accepts Y) would silently expose private posts.
//
// Returns the post row on success. Throws AppError(404) if the post
// is missing, soft-deleted, or inaccessible to the requester. Using
// the same status for missing and private posts avoids confirming
// that a private post id exists.

import { query } from '../db/pool';
import { AppError } from '../middleware/errorHandler';
import { isMutualFollow } from '../helpers';

export async function verifyPostAccess(postId: string, userId: string) {
  const { rows: posts } = await query(
    `SELECT id, user_id
       FROM posts
      WHERE id = $1
        AND deleted_at IS NULL
        AND (expires_at IS NULL OR expires_at > NOW() OR user_id = $2)`,
    [postId, userId],
  );
  if (posts.length === 0) throw new AppError(404, 'Post not found');

  const post = posts[0];

  if (post.user_id !== userId) {
    const mutual = await isMutualFollow(userId, post.user_id);
    if (!mutual) throw new AppError(404, 'Post not found');

    // Group scoping: if the post is scoped to one or more groups,
    // viewer must be a member of at least one of them.
    const { rows: postGroups } = await query(
      'SELECT group_id FROM post_groups WHERE post_id = $1',
      [postId],
    );
    if (postGroups.length > 0) {
      const groupIds = postGroups.map((pg: any) => pg.group_id);
      const { rows: membership } = await query(
        'SELECT 1 FROM group_members WHERE group_id = ANY($1) AND member_user_id = $2 LIMIT 1',
        [groupIds, userId],
      );
      if (membership.length === 0) {
        throw new AppError(404, 'Post not found');
      }
    }
  }

  return post;
}
