import { Router } from 'express';
import { v4 as uuidv4 } from 'uuid';
import { query } from '../db/pool';
import { writeLimit } from '../middleware/rateLimit';
import { asyncHandler, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { config } from '../config';
import { getPresignedUploadUrl } from '../storage';

const router = Router();

// GET / - List active stories from mutual follows + own stories, grouped by user
router.get(
  '/',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    const { rows: stories } = await query(
      `SELECT s.*, u.username, u.display_name, u.avatar_url
       FROM stories s
       JOIN users u ON u.id = s.user_id
       WHERE s.expires_at > NOW()
         AND (
           s.user_id = $1
           OR s.user_id IN (
             SELECT f1.followee_id FROM follows f1
             JOIN follows f2 ON f2.follower_id = f1.followee_id AND f2.followee_id = f1.follower_id
             WHERE f1.follower_id = $1
           )
         )
       ORDER BY s.user_id, s.created_at ASC`,
      [userId],
    );

    // Group by user
    const grouped = new Map<string, { user: any; stories: any[] }>();
    for (const story of stories) {
      // Resolve media URL for dev/prod
      story.media_url = resolveMediaUrl(story.media_url, req);
      if (story.avatar_url) {
        story.avatar_url = resolveMediaUrl(story.avatar_url, req);
      }

      if (!grouped.has(story.user_id)) {
        grouped.set(story.user_id, {
          user: {
            id: story.user_id,
            username: story.username,
            display_name: story.display_name,
            avatar_url: story.avatar_url,
          },
          stories: [],
        });
      }
      grouped.get(story.user_id)!.stories.push(story);
    }

    res.json({ story_groups: Array.from(grouped.values()) });
  }),
);

// POST /upload-url - Get presigned upload URL for story media
router.post(
  '/upload-url',
  asyncHandler(async (req: any, res: any) => {
    const { content_type } = req.body;
    if (!content_type) throw new AppError(400, 'content_type is required');

    const key = `${uuidv4()}`;
    const isDev = config.nodeEnv === 'development' || config.nodeEnv === 'test';

    let upload_url: string;
    if (isDev) {
      const host = req.get('x-forwarded-host') || req.get('host');
      const proto = req.get('x-forwarded-proto') || req.protocol;
      const baseUrl = `${proto}://${host}`;
      upload_url = `${baseUrl}/v1/posts/upload/${key}`;
    } else {
      upload_url = await getPresignedUploadUrl(key, content_type);
    }

    res.json({ upload_url, key });
  }),
);

// POST / - Create a story
router.post(
  '/',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { key, media_type } = req.body;

    if (!key) throw new AppError(400, 'key is required');
    if (!media_type) throw new AppError(400, 'media_type is required');

    const { rows: stories } = await query(
      `INSERT INTO stories (user_id, media_url, media_type, expires_at)
       VALUES ($1, $2, $3, NOW() + INTERVAL '24 hours')
       RETURNING *`,
      [userId, key, media_type],
    );

    const story = stories[0];
    story.media_url = resolveMediaUrl(story.media_url, req);

    res.status(201).json({ story });
  }),
);

// DELETE /:id - Hard-delete own story
router.delete(
  '/:id',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    const { rowCount } = await query(
      'DELETE FROM stories WHERE id = $1 AND user_id = $2',
      [id, userId],
    );
    if (rowCount === 0) throw new AppError(404, 'Story not found');

    res.json({ message: 'Story deleted' });
  }),
);

export default router;
