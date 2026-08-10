import { getClient } from '../db/pool';

/**
 * Permanently delete a user and their dependent relational data.
 * Foreign-key policy lives in migration 027; this service handles the one
 * domain rule a cascade cannot express: group-conversation admin handoff.
 */
export async function permanentlyDeleteUser(userId: string): Promise<boolean> {
  const client = await getClient();
  try {
    await client.query('BEGIN');
    const { rows: users } = await client.query(
      'SELECT id FROM users WHERE id = $1 FOR UPDATE',
      [userId],
    );
    if (users.length === 0) {
      await client.query('ROLLBACK');
      return false;
    }

    const { rows: creatorships } = await client.query(
      `SELECT id
         FROM conversations
        WHERE conversation_type = 'group'
          AND created_by = $1
        FOR UPDATE`,
      [userId],
    );

    for (const { id: conversationId } of creatorships) {
      const { rows: nextAdmin } = await client.query(
        `SELECT user_id
           FROM conversation_members
          WHERE conversation_id = $1
            AND user_id != $2
          ORDER BY joined_at ASC, id ASC
          LIMIT 1`,
        [conversationId, userId],
      );
      if (nextAdmin.length > 0) {
        await client.query(
          'UPDATE conversations SET created_by = $1 WHERE id = $2',
          [nextAdmin[0].user_id, conversationId],
        );
      } else {
        await client.query('DELETE FROM conversations WHERE id = $1', [conversationId]);
      }
    }

    await client.query('DELETE FROM users WHERE id = $1', [userId]);
    await client.query('COMMIT');
    return true;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}
