import { query } from '../db/pool';
import { deleteStorageObjects } from '../storage';

export async function processMediaDeletionQueue(limit = 500): Promise<number> {
  const { rows } = await query<{ object_key: string }>(
    `UPDATE media_deletion_queue
        SET attempts = attempts + 1,
            last_attempt_at = NOW(),
            last_error = NULL
      WHERE object_key IN (
        SELECT object_key
          FROM media_deletion_queue
         WHERE last_attempt_at IS NULL
            OR last_attempt_at < NOW() - INTERVAL '5 minutes'
         ORDER BY enqueued_at ASC
         LIMIT $1
         FOR UPDATE SKIP LOCKED
      )
      RETURNING object_key`,
    [limit],
  );
  if (rows.length === 0) return 0;

  const keys = rows.map((row) => row.object_key);
  try {
    await deleteStorageObjects(keys);
    await query('DELETE FROM media_deletion_queue WHERE object_key = ANY($1::text[])', [keys]);
    return keys.length;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await query(
      `UPDATE media_deletion_queue
          SET last_error = $2
        WHERE object_key = ANY($1::text[])`,
      [keys, message.slice(0, 1000)],
    );
    throw err;
  }
}
