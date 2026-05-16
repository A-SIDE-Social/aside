/**
 * Push throttle integration tests.
 *
 * The throttle reuses the existing `notifications.push_sent_at`
 * column as the per-recipient delivery log. Tests cover:
 *
 *   1. filterByPushThrottle drops recipients who got a push in the
 *      last 5 min, keeps everyone else.
 *   2. stampPushSent marks the most recent un-stamped notification
 *      per user, but only one row per user (not all recent rows).
 *   3. End-to-end: a second follow request to the same user inside
 *      the window does NOT generate a stamp / would not have fired
 *      a push.
 *
 * Live-DB style mirrors api.test.ts.
 */
import http from 'http';
import fs from 'fs';
import path from 'path';
import { app } from '../src/app';
import { pool, query } from '../src/db/pool';
import { initSocket } from '../src/socket';
import {
  filterByPushThrottle,
  stampPushSent,
} from '../src/firebase';

let server: http.Server;

async function createTestUser() {
  const autoUsername = `u${Math.random().toString(36).slice(2, 18)}`;
  const email = `pt-${Math.random().toString(36).slice(2, 10)}@test.com`;
  const { rows } = await query(
    `INSERT INTO users (username, display_name, email)
     VALUES ($1, $2, $3) RETURNING *`,
    [autoUsername, 'Test User', email],
  );
  return rows[0];
}

beforeAll(async () => {
  await query(`
    DROP SCHEMA public CASCADE;
    CREATE SCHEMA public;
    GRANT ALL ON SCHEMA public TO public;
  `);
  const migrationsDir = path.join(__dirname, '../src/db/migrations');
  const files = fs.readdirSync(migrationsDir).filter(f => f.endsWith('.sql')).sort();
  for (const file of files) {
    const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    await query(sql);
  }
  server = http.createServer(app);
  initSocket(server);
  await new Promise<void>((resolve) => server.listen(0, resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
});

describe('filterByPushThrottle', () => {
  test('keeps a user who has never been pushed', async () => {
    const user = await createTestUser();
    const allowed = await filterByPushThrottle([user.id]);
    expect(allowed).toContain(user.id);
  });

  test('drops a user who has a push_sent_at within the last 5 minutes', async () => {
    const user = await createTestUser();
    const other = await createTestUser();
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type, push_sent_at)
       VALUES ($1, 'comment', $2, 'post', NOW())`,
      [user.id, other.id],
    );
    const allowed = await filterByPushThrottle([user.id]);
    expect(allowed).not.toContain(user.id);
  });

  test('keeps a user whose last push_sent_at is older than 5 minutes', async () => {
    const user = await createTestUser();
    const other = await createTestUser();
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type, push_sent_at)
       VALUES ($1, 'comment', $2, 'post', NOW() - INTERVAL '6 minutes')`,
      [user.id, other.id],
    );
    const allowed = await filterByPushThrottle([user.id]);
    expect(allowed).toContain(user.id);
  });

  test('keeps a user whose notification has NULL push_sent_at (insert without delivery)', async () => {
    // A notification was inserted but never pushed (e.g. throttled
    // upstream, or recipient had no tokens). The throttle window
    // should not count those — only successful deliveries gate.
    const user = await createTestUser();
    const other = await createTestUser();
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type)
       VALUES ($1, 'comment', $2, 'post')`,
      [user.id, other.id],
    );
    const allowed = await filterByPushThrottle([user.id]);
    expect(allowed).toContain(user.id);
  });

  test('mixed batch: keeps recent-quiet users, drops recent-pushed users', async () => {
    const quiet = await createTestUser();
    const noisy = await createTestUser();
    const other = await createTestUser();
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type, push_sent_at)
       VALUES ($1, 'comment', $2, 'post', NOW())`,
      [noisy.id, other.id],
    );
    const allowed = await filterByPushThrottle([quiet.id, noisy.id]);
    expect(allowed).toContain(quiet.id);
    expect(allowed).not.toContain(noisy.id);
  });

  test('empty input returns empty', async () => {
    const allowed = await filterByPushThrottle([]);
    expect(allowed).toEqual([]);
  });
});

describe('stampPushSent', () => {
  test('marks the most recent un-stamped notification for the user', async () => {
    const user = await createTestUser();
    const other = await createTestUser();
    const { rows } = await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type)
       VALUES ($1, 'inbound_follow', $2, 'follow') RETURNING id`,
      [user.id, other.id],
    );
    const notifId = rows[0].id;

    await stampPushSent([user.id]);

    const { rows: after } = await query(
      'SELECT push_sent_at FROM notifications WHERE id = $1',
      [notifId],
    );
    expect(after[0].push_sent_at).not.toBeNull();
  });

  test('stamps only ONE notification per user even with multiple recent un-stamped rows', async () => {
    // Several inserts close together (e.g. a fanout where multiple
    // notification types fired) should still stamp just one row — we
    // want one "push event" per stamp, not all backlogged inserts.
    const user = await createTestUser();
    const other = await createTestUser();
    for (let i = 0; i < 3; i++) {
      await query(
        `INSERT INTO notifications (user_id, type, actor_id, reference_type)
         VALUES ($1, 'comment', $2, 'post')`,
        [user.id, other.id],
      );
    }
    await stampPushSent([user.id]);

    const { rows } = await query(
      `SELECT COUNT(*)::int AS stamped
       FROM notifications
       WHERE user_id = $1 AND push_sent_at IS NOT NULL`,
      [user.id],
    );
    expect(rows[0].stamped).toBe(1);
  });

  test('does NOT stamp older un-pushed notifications (>30s old)', async () => {
    // Bound exists so a retry running well after the original
    // insert can't accidentally stamp an unrelated old row.
    const user = await createTestUser();
    const other = await createTestUser();
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type, created_at)
       VALUES ($1, 'comment', $2, 'post', NOW() - INTERVAL '5 minutes')`,
      [user.id, other.id],
    );

    await stampPushSent([user.id]);

    const { rows } = await query(
      `SELECT push_sent_at FROM notifications WHERE user_id = $1`,
      [user.id],
    );
    expect(rows[0].push_sent_at).toBeNull();
  });

  test('empty input is a no-op', async () => {
    await expect(stampPushSent([])).resolves.toBeUndefined();
  });
});

describe('throttle end-to-end semantics', () => {
  test('after stampPushSent, the same user is filtered out for 5 minutes', async () => {
    const user = await createTestUser();
    const other = await createTestUser();
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type)
       VALUES ($1, 'comment', $2, 'post')`,
      [user.id, other.id],
    );

    // Before stamping, user is allowed.
    let allowed = await filterByPushThrottle([user.id]);
    expect(allowed).toContain(user.id);

    // After stamping, user is blocked.
    await stampPushSent([user.id]);
    allowed = await filterByPushThrottle([user.id]);
    expect(allowed).not.toContain(user.id);
  });

  test('different users do not affect each other\'s throttle state', async () => {
    const alice = await createTestUser();
    const bob = await createTestUser();
    const other = await createTestUser();

    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type, push_sent_at)
       VALUES ($1, 'comment', $2, 'post', NOW())`,
      [alice.id, other.id],
    );

    const allowed = await filterByPushThrottle([alice.id, bob.id]);
    expect(allowed).not.toContain(alice.id);
    expect(allowed).toContain(bob.id);
  });
});
