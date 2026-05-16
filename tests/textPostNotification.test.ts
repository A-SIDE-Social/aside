/**
 * Regression test for text-only post push notifications.
 *
 * Why an isolated test file (not in api.test.ts):
 *
 *   `tests/api.test.ts` does `import { app } from '../src/app'` at line 4,
 *   which transitively imports `src/routes/posts.ts`, which has a static
 *   `import { notifyNewPost } from '../firebase'`. Once that import
 *   resolves, the binding inside posts.ts captures whatever is in firebase
 *   at that moment. A `jest.spyOn` installed AFTER the import won't
 *   intercept calls made through the captured binding — they go to the
 *   real notifyNewPost.
 *
 *   The fix: hoisted `jest.mock('../src/firebase', factory)` at the top of
 *   this file. Jest's transformer hoists `jest.mock()` calls above all
 *   imports, so the mock is registered before posts.ts captures the
 *   binding. Subsequent `import { notifyNewPost } from '../src/firebase'`
 *   in this test file gets the mock object too.
 *
 * What this test guards: text-only posts (caption only, no media) must
 * still fire `notifyNewPost`. Earlier in the codebase's life this was a
 * real risk because the fan-out was conditionally gated on media; today
 * it isn't, but a future refactor might re-introduce that gate.
 */

// Hoisted by Jest's transformer above the imports below. Wraps the real
// firebase module so other functions (sendPushWithBadge etc.) keep
// working — only notifyNewPost becomes a mock.
jest.mock('../src/firebase', () => ({
  ...jest.requireActual('../src/firebase'),
  notifyNewPost: jest.fn(),
}));

import request from 'supertest';
import fs from 'fs';
import path from 'path';
import { app } from '../src/app';
import { query } from '../src/db/pool';
import { generateAccessToken } from '../src/middleware/auth';
import { notifyNewPost } from '../src/firebase';

const mockNotifyNewPost = notifyNewPost as jest.Mock;

// Inline minimal user + follow helpers so this file stands alone (no
// dependency on tests/api.test.ts internals).
async function createTestUser(displayName: string, email: string) {
  const autoUsername = `u${Math.random().toString(36).slice(2, 18)}`;
  const { rows } = await query(
    `INSERT INTO users (username, display_name, email, subscription_status)
     VALUES ($1, $2, $3, 'free')
     RETURNING *`,
    [autoUsername, displayName, email],
  );
  return { user: rows[0], token: generateAccessToken(rows[0].id) };
}

async function createMutualFollow(a: string, b: string) {
  await query(
    `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2), ($2, $1)
     ON CONFLICT DO NOTHING`,
    [a, b],
  );
}

/**
 * The route handler calls `notifyNewPost(...)` AFTER `res.status(201)
 * .json(post)` — fire-and-forget so the client gets its response
 * without waiting on FCM. supertest's await resolves on the response
 * send, so the mock may not be called yet by the time we assert.
 *
 * Poll up to ~1 s for the mock to be invoked. In practice it lands
 * within one event-loop tick.
 */
async function waitFor(condition: () => boolean, timeoutMs = 1000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`waitFor timed out after ${timeoutMs}ms`);
}

beforeAll(async () => {
  // Same schema-reset + migration-apply pattern as api.test.ts —
  // reduces inter-file ordering surprises when this file runs in
  // a suite alongside others.
  await query(`
    DROP SCHEMA public CASCADE;
    CREATE SCHEMA public;
    GRANT ALL ON SCHEMA public TO public;
  `);
  const migrationsDir = path.join(__dirname, '../src/db/migrations');
  const migrationFiles = fs
    .readdirSync(migrationsDir)
    .filter((f) => f.endsWith('.sql'))
    .sort();
  for (const file of migrationFiles) {
    const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    await query(sql);
  }
});

beforeEach(() => {
  mockNotifyNewPost.mockClear();
});

describe('text-only post notifications', () => {
  test('Text-only post (no media) still fires notifyNewPost', async () => {
    const { user: poster, token: posterToken } = await createTestUser(
      'Text Poster',
      `txt-poster-${Date.now()}@test.com`,
    );
    const { user: follower } = await createTestUser(
      'Text Follower',
      `txt-follower-${Date.now()}@test.com`,
    );
    await createMutualFollow(poster.id, follower.id);

    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${posterToken}`)
      .send({ caption: 'Just thinking out loud today.' });

    expect(res.status).toBe(201);
    expect(res.body.post).toBeDefined();
    const postId = res.body.post.id;

    // Fan-out fires regardless of media presence — but it's invoked
    // post-response, so wait for it to land.
    await waitFor(() => mockNotifyNewPost.mock.calls.length === 1);
    const callArgs = mockNotifyNewPost.mock.calls[0];
    // Signature: notifyNewPost(posterId, posterName, caption, postId, mediaTypes, imageUrl?)
    expect(callArgs[0]).toBe(poster.id);
    expect(callArgs[1]).toBe('Text Poster');
    expect(callArgs[2]).toBe('Just thinking out loud today.');
    expect(callArgs[3]).toBe(postId);
    expect(callArgs[4]).toEqual([]); // no mediaTypes for a text post
    expect(callArgs[5]).toBeUndefined(); // no imageUrl for a text post
  });

  test('Photo post fires notifyNewPost with media + image_url', async () => {
    // Sanity check that the media path also still works — guards
    // against a regression where adding/removing the text path breaks
    // the original photo path.
    const { user: poster, token: posterToken } = await createTestUser(
      'Photo Poster',
      `photo-poster-${Date.now()}@test.com`,
    );
    const { user: follower } = await createTestUser(
      'Photo Follower',
      `photo-follower-${Date.now()}@test.com`,
    );
    await createMutualFollow(poster.id, follower.id);

    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${posterToken}`)
      .send({
        caption: 'with photo',
        media: [
          {
            key: 'media/test-photo.jpg',
            media_type: 'photo',
            position: 0,
          },
        ],
      });

    expect(res.status).toBe(201);
    await waitFor(() => mockNotifyNewPost.mock.calls.length === 1);
    const callArgs = mockNotifyNewPost.mock.calls[0];
    expect(callArgs[4]).toEqual(['photo']);
    expect(typeof callArgs[5]).toBe('string'); // image_url present
  });
});
