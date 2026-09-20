import { getClient, query } from '../db/pool';
import { AppError } from '../middleware/errorHandler';
import { SYSTEM_USER_EMAIL } from '../constants';
import { sendPush, getTokensForUsers, filterByPushThrottle, stampPushSent } from '../firebase';

type Target = { userId: string } | { slug: string };

/** One transaction for the edge and the durable notification. Serialize both
 * directions of a pair so simultaneous requests become one mutual connection. */
export async function createConnection(callerId: string, target: Target) {
  const client = await getClient();
  try {
    await client.query('BEGIN');
    const bySlug = 'slug' in target;
    const { rows: users } = await client.query(
      `SELECT id FROM users
       WHERE ${bySlug ? 'LOWER(invite_slug) = LOWER($1)' : 'id = $1'}
         AND deleted_at IS NULL AND email IS DISTINCT FROM $2
       FOR SHARE`,
      [bySlug ? target.slug : target.userId, SYSTEM_USER_EMAIL],
    );
    if (!users.length) throw new AppError(404, bySlug ? 'Invite link not found' : 'User not found');
    const targetId: string = users[0].id;
    if (callerId === targetId) {
      await client.query('COMMIT');
      return { self: true, isNew: false, isMutual: false, targetId, callerId, callerName: '', follow: null };
    }
    const pair = [callerId, targetId].sort();
    await client.query('SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))', pair);
    const { rows: inserted } = await client.query(
      `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)
       ON CONFLICT (follower_id, followee_id) DO NOTHING RETURNING *`,
      [callerId, targetId],
    );
    const isNew = inserted.length > 0;
    const { rows: reverse } = await client.query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2', [targetId, callerId],
    );
    const isMutual = reverse.length > 0;
    let follow = inserted[0];
    if (!follow) {
      const { rows } = await client.query(
        'SELECT * FROM follows WHERE follower_id = $1 AND followee_id = $2', [callerId, targetId],
      );
      follow = rows[0];
    }
    if (isNew) {
      if (isMutual) {
        await client.query(
          `INSERT INTO notifications (user_id, type, actor_id, reference_type)
           VALUES ($1, 'new_mutual', $2, 'follow'), ($2, 'new_mutual', $1, 'follow')`,
          [callerId, targetId],
        );
      } else {
        await client.query(
          `INSERT INTO notifications (user_id, type, actor_id, reference_type)
           VALUES ($1, 'inbound_follow', $2, 'follow')`, [targetId, callerId],
        );
      }
    }
    const { rows: caller } = await client.query('SELECT display_name FROM users WHERE id = $1', [callerId]);
    await client.query('COMMIT');
    return { self: false, isNew, isMutual, targetId, callerId,
      callerName: caller[0]?.display_name || 'Someone', follow };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

/** Push is an optional delivery channel, never the success criterion. */
export async function pushConnection(result: Awaited<ReturnType<typeof createConnection>>) {
  if (!result.isNew) return;
  try {
    const { rows } = await query(
      'SELECT COALESCE((SELECT connections FROM notification_preferences WHERE user_id = $1), true) AS enabled',
      [result.targetId],
    );
    if (!rows[0].enabled) return;
    const allowed = await filterByPushThrottle([result.targetId]);
    if (!allowed.length) return;
    const tokens = await getTokensForUsers([result.targetId]);
    if (!tokens.length) return;
    await sendPush(tokens,
      result.isMutual ? 'New Connection' : 'Connection Request',
      result.isMutual ? `You and ${result.callerName} are now connected` : `${result.callerName} wants to connect with you`,
      { type: result.isMutual ? 'new_mutual' : 'inbound_follow', user_id: result.callerId });
    await stampPushSent([result.targetId]);
  } catch (error) {
    console.warn('Connection push delivery failed after commit');
  }
}
