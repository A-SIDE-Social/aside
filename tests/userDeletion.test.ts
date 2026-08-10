import request from 'supertest';
import {
  app,
  createTestUser,
  query,
  setupTestServer,
} from './helpers';

setupTestServer();

describe('User deletion policy', () => {
  test('every direct users foreign key has an explicit cascade or set-null policy', async () => {
    const { rows } = await query(
      `SELECT tc.table_name, kcu.column_name, rc.delete_rule
         FROM information_schema.table_constraints tc
         JOIN information_schema.key_column_usage kcu
           ON kcu.constraint_schema = tc.constraint_schema
          AND kcu.constraint_name = tc.constraint_name
         JOIN information_schema.referential_constraints rc
           ON rc.constraint_schema = tc.constraint_schema
          AND rc.constraint_name = tc.constraint_name
         JOIN information_schema.constraint_column_usage ccu
           ON ccu.constraint_schema = rc.unique_constraint_schema
          AND ccu.constraint_name = rc.unique_constraint_name
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND ccu.table_name = 'users'
        ORDER BY tc.table_name, kcu.column_name`,
    );

    expect(rows).toHaveLength(32);
    expect(rows.filter((row) => row.delete_rule === 'NO ACTION')).toEqual([]);
    expect(
      rows
        .filter((row) => row.delete_rule === 'SET NULL')
        .map((row) => `${row.table_name}.${row.column_name}`)
        .sort(),
    ).toEqual([
      'admin_audit.admin_user_id',
      'admin_audit.target_user_id',
      'broadcasts.initiated_by_user_id',
      'conversations.created_by',
      'invites.used_by_user_id',
      'notifications.actor_id',
    ]);
  });

  test('permanent deletion removes private data and preserves anonymized shared history', async () => {
    const { user, token } = await createTestUser();
    const { user: peer } = await createTestUser();

    await query('UPDATE users SET avatar_url = $1 WHERE id = $2', [
      `avatars/${user.id}.jpg`,
      user.id,
    ]);
    await query(
      `INSERT INTO follows (follower_id, followee_id)
       VALUES ($1, $2), ($2, $1)`,
      [user.id, peer.id],
    );
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
      [user.id, `owned${user.id.slice(0, 8)}`],
    );
    const { rows: peerInvite } = await query(
      `INSERT INTO invites
         (created_by_user_id, used_by_user_id, code, status, expires_at, used_at)
       VALUES ($1, $2, $3, 'used', NOW() + INTERVAL '30 days', NOW())
       RETURNING id`,
      [peer.id, user.id, `used${user.id.slice(0, 8)}`],
    );

    const { rows: posts } = await query(
      `INSERT INTO posts (user_id, caption) VALUES ($1, 'delete me') RETURNING id`,
      [user.id],
    );
    await query(
      `INSERT INTO post_media
         (post_id, position, media_url, thumbnail_url, media_type)
       VALUES ($1, 0, $2, $3, 'photo')`,
      [posts[0].id, `posts/${user.id}.jpg`, `thumbs/${user.id}.jpg`],
    );
    const { rows: peerPosts } = await query(
      `INSERT INTO posts (user_id, caption) VALUES ($1, 'keep me') RETURNING id`,
      [peer.id],
    );
    await query(
      `INSERT INTO comments (post_id, user_id, body)
       VALUES ($1, $2, 'delete this comment')`,
      [peerPosts[0].id, user.id],
    );
    await query(
      `INSERT INTO stories (user_id, media_url, media_type, expires_at)
       VALUES ($1, $2, 'photo', NOW() + INTERVAL '1 day')`,
      [user.id, `stories/${user.id}.jpg`],
    );

    const [userA, userB] = [user.id, peer.id].sort();
    const { rows: direct } = await query(
      `INSERT INTO conversations (user_a_id, user_b_id)
       VALUES ($1, $2) RETURNING id`,
      [userA, userB],
    );
    await query(
      `INSERT INTO conversation_members (conversation_id, user_id)
       VALUES ($1, $2), ($1, $3)`,
      [direct[0].id, user.id, peer.id],
    );
    await query(
      `INSERT INTO messages
         (conversation_id, sender_id, body, envelope_type)
       VALUES ($1, $2, 'delete direct conversation', 'legacy_plaintext')`,
      [direct[0].id, user.id],
    );

    const { rows: group } = await query(
      `INSERT INTO conversations
         (conversation_type, name, created_by, user_a_id, user_b_id)
       VALUES ('group', 'Keep group', $1, NULL, NULL)
       RETURNING id`,
      [user.id],
    );
    await query(
      `INSERT INTO conversation_members (conversation_id, user_id)
       VALUES ($1, $2), ($1, $3)`,
      [group[0].id, user.id, peer.id],
    );
    await query(
      `INSERT INTO messages
         (conversation_id, sender_id, body, envelope_type)
       VALUES ($1, $2, 'delete group message', 'legacy_plaintext')`,
      [group[0].id, user.id],
    );

    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type)
       VALUES ($1, 'inbound_follow', $2, 'follow'),
              ($2, 'inbound_follow', $1, 'follow')`,
      [user.id, peer.id],
    );
    await query(
      `INSERT INTO refresh_tokens (user_id, token_hash, expires_at)
       VALUES ($1, $2, NOW() + INTERVAL '1 year')`,
      [user.id, `hash-${user.id}`],
    );
    await query(
      `INSERT INTO dm_attachment_objects (object_key, uploaded_by_user_id)
       VALUES ($1, $2)`,
      [`dm/${user.id}`, user.id],
    );

    const { rows: audits } = await query(
      `INSERT INTO admin_audit
         (admin_user_id, action, target_user_id, details)
       VALUES
         ($1, 'change_email', $2, '{"from":"private@example.com"}'),
         ($2, 'restore', $1, '{"reason":"operator action"}')
       RETURNING id, action`,
      [peer.id, user.id],
    );
    const targetAudit = audits.find((row) => row.action === 'change_email');
    const operatorAudit = audits.find((row) => row.action === 'restore');
    const { rows: broadcasts } = await query(
      `INSERT INTO broadcasts
         (template_key, subject, initiated_by_user_id, recipient_count)
       VALUES ('test', 'Test', $1, 1)
       RETURNING id`,
      [user.id],
    );

    const { rows: familyGroups } = await query(
      `INSERT INTO family_groups (owner_id) VALUES ($1) RETURNING id`,
      [user.id],
    );
    await query('UPDATE users SET family_group_id = $1 WHERE id = $2', [
      familyGroups[0].id,
      peer.id,
    ]);

    const res = await request(app)
      .delete('/v1/users/me')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);

    expect((await query('SELECT 1 FROM users WHERE id = $1', [user.id])).rows).toHaveLength(0);
    expect((await query('SELECT 1 FROM posts WHERE user_id = $1', [user.id])).rows).toHaveLength(0);
    expect((await query('SELECT 1 FROM comments WHERE user_id = $1', [user.id])).rows).toHaveLength(0);
    expect((await query('SELECT 1 FROM stories WHERE user_id = $1', [user.id])).rows).toHaveLength(0);
    expect((await query('SELECT 1 FROM follows WHERE follower_id = $1 OR followee_id = $1', [user.id])).rows).toHaveLength(0);
    expect((await query('SELECT 1 FROM refresh_tokens WHERE user_id = $1', [user.id])).rows).toHaveLength(0);
    expect((await query('SELECT 1 FROM conversations WHERE id = $1', [direct[0].id])).rows).toHaveLength(0);

    const { rows: keptGroup } = await query(
      'SELECT created_by FROM conversations WHERE id = $1',
      [group[0].id],
    );
    expect(keptGroup[0].created_by).toBe(peer.id);
    expect((await query('SELECT user_id FROM conversation_members WHERE conversation_id = $1', [group[0].id])).rows)
      .toEqual([{ user_id: peer.id }]);
    expect((await query('SELECT 1 FROM messages WHERE conversation_id = $1', [group[0].id])).rows)
      .toHaveLength(0);

    const { rows: retainedInvite } = await query(
      'SELECT status, used_by_user_id FROM invites WHERE id = $1',
      [peerInvite[0].id],
    );
    expect(retainedInvite[0]).toEqual({ status: 'used', used_by_user_id: null });
    const { rows: retainedNotification } = await query(
      `SELECT actor_id FROM notifications
       WHERE user_id = $1 AND type = 'inbound_follow'`,
      [peer.id],
    );
    expect(retainedNotification).toEqual([{ actor_id: null }]);

    const { rows: targetAuditAfter } = await query(
      'SELECT target_user_id, details FROM admin_audit WHERE id = $1',
      [targetAudit.id],
    );
    expect(targetAuditAfter[0]).toEqual({ target_user_id: null, details: null });
    const { rows: operatorAuditAfter } = await query(
      'SELECT admin_user_id FROM admin_audit WHERE id = $1',
      [operatorAudit.id],
    );
    expect(operatorAuditAfter[0].admin_user_id).toBeNull();
    expect((await query('SELECT initiated_by_user_id FROM broadcasts WHERE id = $1', [broadcasts[0].id])).rows[0].initiated_by_user_id)
      .toBeNull();
    expect((await query('SELECT family_group_id FROM users WHERE id = $1', [peer.id])).rows[0].family_group_id)
      .toBeNull();
    expect((await query('SELECT 1 FROM dm_attachment_objects WHERE uploaded_by_user_id = $1', [user.id])).rows)
      .toHaveLength(0);
  });

  test('direct SQL deletion durably queues every attributable storage object', async () => {
    const { user } = await createTestUser();
    const { user: peer } = await createTestUser();
    await query('UPDATE users SET avatar_url = $1 WHERE id = $2', ['avatars/direct.jpg', user.id]);
    const { rows: posts } = await query(
      `INSERT INTO posts (user_id, caption) VALUES ($1, 'media') RETURNING id`,
      [user.id],
    );
    await query(
      `INSERT INTO post_media
         (post_id, position, media_url, thumbnail_url, media_type)
       VALUES ($1, 0, 'posts/direct.jpg', 'thumbs/direct.jpg', 'photo')`,
      [posts[0].id],
    );
    await query(
      `INSERT INTO stories (user_id, media_url, media_type, expires_at)
       VALUES ($1, 'stories/direct.jpg', 'photo', NOW() + INTERVAL '1 day')`,
      [user.id],
    );
    await query(
      `INSERT INTO dm_attachment_objects (object_key, uploaded_by_user_id)
       VALUES ('dm/direct', $1)`,
      [user.id],
    );

    const [userA, userB] = [user.id, peer.id].sort();
    const { rows: direct } = await query(
      `INSERT INTO conversations (user_a_id, user_b_id)
       VALUES ($1, $2) RETURNING id`,
      [userA, userB],
    );
    await query(
      `INSERT INTO messages
         (conversation_id, sender_id, media_url, envelope_type)
       VALUES ($1, $2, 'messages/direct.jpg', 'legacy_plaintext')`,
      [direct[0].id, peer.id],
    );

    await query('DELETE FROM users WHERE id = $1', [user.id]);

    const { rows: queued } = await query(
      'SELECT object_key FROM media_deletion_queue ORDER BY object_key',
    );
    expect(queued.map((row) => row.object_key)).toEqual([
      'avatars/direct.jpg',
      'dm/direct',
      'messages/direct.jpg',
      'posts/direct.jpg',
      'stories/direct.jpg',
      'thumbs/direct.jpg',
    ]);
  });

  test('failure rolls back group handoff and user deletion together', async () => {
    const { user, token } = await createTestUser();
    const { user: peer } = await createTestUser();
    const { rows: groups } = await query(
      `INSERT INTO conversations
         (conversation_type, name, created_by, user_a_id, user_b_id)
       VALUES ('group', 'Rollback group', $1, NULL, NULL)
       RETURNING id`,
      [user.id],
    );
    await query(
      `INSERT INTO conversation_members (conversation_id, user_id)
       VALUES ($1, $2), ($1, $3)`,
      [groups[0].id, user.id, peer.id],
    );
    await query(`
      CREATE FUNCTION test_fail_user_delete() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'forced user deletion failure';
      END;
      $$ LANGUAGE plpgsql
    `);
    await query(`
      CREATE TRIGGER zzz_test_fail_user_delete
      BEFORE DELETE ON users
      FOR EACH ROW EXECUTE FUNCTION test_fail_user_delete()
    `);

    try {
      const res = await request(app)
        .delete('/v1/users/me')
        .set('Authorization', `Bearer ${token}`);
      expect(res.status).toBe(500);
    } finally {
      await query('DROP TRIGGER zzz_test_fail_user_delete ON users');
      await query('DROP FUNCTION test_fail_user_delete()');
    }

    expect((await query('SELECT 1 FROM users WHERE id = $1', [user.id])).rows).toHaveLength(1);
    expect((await query('SELECT created_by FROM conversations WHERE id = $1', [groups[0].id])).rows[0].created_by)
      .toBe(user.id);
  });
});
