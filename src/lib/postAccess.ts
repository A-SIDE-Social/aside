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
import { postAudiencePredicate } from './postAudience';

export async function verifyPostAccess(postId: string, userId: string) {
  const { rows: posts } = await query(
    `SELECT p.id, p.user_id
       FROM posts p
      WHERE p.id = $1
        AND p.deleted_at IS NULL
        AND (p.expires_at IS NULL OR p.expires_at > NOW() OR p.user_id = $2)
        AND (
          p.user_id = $2
          OR (
            EXISTS (
              SELECT 1
                FROM follows outbound
                JOIN follows inbound
                  ON inbound.follower_id = outbound.followee_id
                 AND inbound.followee_id = outbound.follower_id
               WHERE outbound.follower_id = $2
                 AND outbound.followee_id = p.user_id
            )
            AND ${postAudiencePredicate('p', '$2')}
          )
        )`,
    [postId, userId],
  );
  if (posts.length === 0) throw new AppError(404, 'Post not found');
  return posts[0];
}
