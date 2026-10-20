import { Router, raw } from 'express';
import { v4 as uuidv4 } from 'uuid';
import { query } from '../db/pool';
import { asyncHandler, getUserSubscriptionStatus } from '../helpers';
import { verifyPostAccess } from '../lib/postAccess';
import { getPlanLimits } from '../constants';
import { AppError } from '../middleware/errorHandler';
import { writeLimit } from '../middleware/rateLimit';
import { putVoiceCaption, readVoiceCaption } from '../storage';

export const voiceCaptionsRouter = Router();

voiceCaptionsRouter.post('/voice-captions', writeLimit,
  raw({ type: 'audio/mp4', limit: '2mb' }),
  asyncHandler(async (req: any, res: any) => {
    const bytes = req.body;
    const duration = Number(req.get('X-Voice-Duration-Ms'));
    if (!Number.isInteger(duration) || duration < 1 || duration > 60000) {
      throw new AppError(400, 'Voice captions must be 60 seconds or less');
    }
    if (!Buffer.isBuffer(bytes) || bytes.length < 12 || bytes.length > 2097152 ||
        bytes.toString('ascii', 4, 8) !== 'ftyp') {
      throw new AppError(400, 'A voice caption must be an M4A recording under 2 MB');
    }
    const userId = req.user!.userId;
    const { rows } = await query(
      'SELECT count(*)::int AS count FROM post_voice_captions WHERE uploaded_by_user_id = $1 AND post_id IS NULL', [userId]);
    if (rows[0].count >= 25) throw new AppError(429, 'Please try uploading the voice caption later');
    const id = uuidv4();
    const key = `voice-captions/${id}.m4a`;
    await query(`INSERT INTO post_voice_captions(id, uploaded_by_user_id, object_key, duration_ms, byte_length)
      VALUES ($1, $2, $3, $4, $5)`, [id, userId, key, duration, bytes.length]);
    try {
      await putVoiceCaption(key, bytes);
    } catch (error) {
      await query('DELETE FROM post_voice_captions WHERE id = $1', [id]);
      throw error;
    }
    // Account deletion can race the object write. A prior cleanup attempt
    // might already have run, so requeue only after the write has completed.
    const attached = await query('SELECT 1 FROM post_voice_captions WHERE id = $1', [id]);
    if (!attached.rowCount) {
      await query(`INSERT INTO media_deletion_queue(object_key) VALUES ($1)
        ON CONFLICT (object_key) DO UPDATE SET last_attempt_at = NULL`, [key]);
      throw new AppError(404, 'Voice caption upload cancelled');
    }
    res.status(201).json({ voice_caption: { id, duration_ms: duration } });
  }));

voiceCaptionsRouter.get('/:id/voice-caption', asyncHandler(async (req: any, res: any) => {
  const userId = req.user!.userId;
  const post = await verifyPostAccess(req.params.id, userId);
  const { rows } = await query(`SELECT v.object_key, p.created_at
    FROM post_voice_captions v JOIN posts p ON p.id = v.post_id
    WHERE v.post_id = $1`, [post.id]);
  if (!rows.length) throw new AppError(404, 'Voice caption not found');
  const { feedHistoryDays } = getPlanLimits(await getUserSubscriptionStatus(userId));
  if (post.user_id !== userId && feedHistoryDays !== null &&
      new Date(rows[0].created_at).getTime() < Date.now() - feedHistoryDays * 86400000) {
    throw new AppError(404, 'Voice caption not found');
  }
  const bytes = await readVoiceCaption(rows[0].object_key);
  res.set('Cache-Control', 'private, no-store').type('audio/mp4').send(bytes);
}));
