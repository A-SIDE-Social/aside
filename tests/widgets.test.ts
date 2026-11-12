import request from 'supertest';
import { app, query, createTestUser, createMutualFollow, setupTestServer } from './helpers';

const db = new URL(process.env.DATABASE_URL || 'postgres://invalid/invalid');
if (!['127.0.0.1', 'localhost'].includes(db.hostname) || !db.pathname.endsWith('_tests')) {
  throw new Error('Widget integration tests require a disposable local _tests database');
}
setupTestServer();
let viewer: Awaited<ReturnType<typeof createTestUser>>;
let friend: Awaited<ReturnType<typeof createTestUser>>;
let outsider: Awaited<ReturnType<typeof createTestUser>>;
let list: string;
const get = (queryString = '') => request(app).get(`/v1/feed/widget${queryString}`).auth(viewer.token, { type: 'bearer' });
async function post(userId: string, options: { old?: boolean; expired?: boolean; private?: boolean; video?: boolean; text?: boolean } = {}) {
  const { rows } = await query(`INSERT INTO posts(user_id, caption, created_at, expires_at, audience_type)
    VALUES ($1, 'Not part of the widget payload', CASE WHEN $2 THEN NOW()-INTERVAL '31 days' ELSE NOW() END,
      CASE WHEN $3 THEN NOW()-INTERVAL '1 day' ELSE NULL END, $4) RETURNING id`,
    [userId, !!options.old, !!options.expired, options.private ? 'lists' : 'all_connections']);
  if (!options.text) await query(`INSERT INTO post_media(post_id, position, media_url, media_type, thumbnail_url)
    VALUES ($1, 0, 'widget-file.jpg', $2, $3)`, [rows[0].id, options.video ? 'video' : 'photo', options.video ? 'widget-thumb.jpg' : null]);
  return rows[0].id as string;
}
beforeAll(async () => {
  viewer = await createTestUser(); friend = await createTestUser(); outsider = await createTestUser();
  await createMutualFollow(viewer.user.id, friend.user.id);
  const result = await query('INSERT INTO groups(user_id, name) VALUES ($1, $2) RETURNING id', [viewer.user.id, 'Family']);
  list = result.rows[0].id;
  await query('INSERT INTO group_members(group_id, member_user_id) VALUES ($1, $2)', [list, friend.user.id]);
});
beforeEach(async () => { await query('DELETE FROM posts'); });
test('requires authentication and validates exclusive selectors', async () => {
  expect((await request(app).get('/v1/feed/widget')).status).toBe(401);
  for (const suffix of ['?user_id=bad', '?group_id=bad', `?user_id=${friend.user.id}&group_id=${list}`, `?user_id=${friend.user.id}&user_id=${outsider.user.id}`]) {
    expect((await get(suffix)).status).toBe(400);
  }
});
test('shows only the latest eligible connection photo with a minimal uncached payload', async () => {
  const eligible = await post(friend.user.id);
  await post(viewer.user.id); await post(outsider.user.id); await post(friend.user.id, { private: true });
  await post(friend.user.id, { expired: true }); await post(friend.user.id, { text: true });
  const response = await get();
  expect(response.status).toBe(200); expect(response.body.post.id).toBe(eligible);
  expect(Object.keys(response.body.post).sort()).toEqual(['display_name', 'expires_at', 'id', 'image_url', 'user_id']);
  expect(response.headers['cache-control']).toContain('no-store');
  expect(response.body.post.image_url).toContain('widget-file.jpg');
});
test('friend and List selectors cannot read unrelated sources', async () => {
  const eligible = await post(friend.user.id);
  expect((await get(`?user_id=${friend.user.id}`)).body.post.id).toBe(eligible);
  expect((await get(`?group_id=${list}`)).body.post.id).toBe(eligible);
  expect((await get(`?user_id=${outsider.user.id}`)).status).toBe(404);
  expect((await request(app).get(`/v1/feed/widget?group_id=${list}`).auth(outsider.token, { type: 'bearer' })).status).toBe(404);
  await query('DELETE FROM group_members WHERE group_id=$1', [list]);
  expect((await get(`?group_id=${list}`)).body.post).toBeNull();
  await query('INSERT INTO group_members(group_id,member_user_id) VALUES ($1,$2)', [list, friend.user.id]);
});
test('history limits, deletion and disconnects apply on the next refresh', async () => {
  await post(friend.user.id, { old: true });
  expect((await get()).body.post).toBeNull();
  await query("UPDATE users SET subscription_status='active' WHERE id=$1", [viewer.user.id]);
  expect((await get()).body.post).not.toBeNull();
  await query('UPDATE posts SET deleted_at=NOW()'); expect((await get()).body.post).toBeNull();
  await query("UPDATE users SET subscription_status='free' WHERE id=$1", [viewer.user.id]);
  await post(friend.user.id); await query('DELETE FROM follows WHERE follower_id=$1 AND followee_id=$2', [viewer.user.id, friend.user.id]);
  expect((await get()).body.post).toBeNull(); expect((await get(`?user_id=${friend.user.id}`)).status).toBe(404);
  await createMutualFollow(viewer.user.id, friend.user.id);
});
test('video uses a thumbnail and text-only feeds return an empty widget', async () => {
  await post(friend.user.id, { video: true }); expect((await get()).body.post.image_url).toContain('widget-thumb.jpg');
  await query('DELETE FROM posts'); await post(friend.user.id, { text: true });
  expect((await get()).body.post).toBeNull();
});

describe('read-only widget credentials', () => {
  const crypto = require('crypto') as typeof import('crypto');
  async function session(userId = viewer.user.id) {
    const secret = `test-${crypto.randomBytes(32).toString('hex')}`;
    const hash = crypto.createHash('sha256').update(secret).digest('hex');
    const { rows } = await query(`INSERT INTO refresh_tokens(user_id,token_hash,expires_at)
      VALUES($1,$2,NOW()+INTERVAL '1 day') RETURNING id`, [userId, hash]);
    return { id: rows[0].id as string, secret };
  }
  const mint = (secret: string) => request(app).post('/v1/widgets/session')
    .auth(viewer.token, { type: 'bearer' }).send({ refresh_token: secret });
  test('requires the current account and a live refresh credential', async () => {
    expect((await request(app).post('/v1/widgets/session').send({ refresh_token: 'test' })).status).toBe(401);
    expect((await mint('missing-session')).status).toBe(409);
    const foreign = await session(outsider.user.id);
    expect((await mint(foreign.secret)).status).toBe(409);
    const own = await session();
    await query('UPDATE refresh_tokens SET expires_at=NOW()-INTERVAL \'1 day\' WHERE id=$1', [own.id]);
    expect((await mint(own.secret)).status).toBe(409);
  });
  test('cannot authorize other API routes, and stops when its session is revoked', async () => {
    const own = await session(); const response = await mint(own.secret);
    expect(response.status).toBe(200); expect(response.headers['cache-control']).toContain('no-store');
    const token = response.body.token as string;
    await post(friend.user.id);
    expect((await request(app).get('/v1/feed/widget').auth(token, { type: 'bearer' })).status).toBe(200);
    for (const path of ['/v1/users/me', '/v1/feed', '/v1/conversations', '/v1/lists']) {
      expect((await request(app).get(path).auth(token, { type: 'bearer' })).status).toBe(401);
    }
    expect((await request(app).post('/v1/widgets/session').auth(token, { type: 'bearer' }).send({ refresh_token: own.secret })).status).toBe(401);
    await query('UPDATE refresh_tokens SET token_hash=$2 WHERE id=$1', [own.id, crypto.createHash('sha256').update('rotated').digest('hex')]);
    expect((await request(app).get('/v1/feed/widget').auth(token, { type: 'bearer' })).status).toBe(200);
    await query('UPDATE refresh_tokens SET revoked_at=NOW() WHERE id=$1', [own.id]);
    expect((await request(app).get('/v1/feed/widget').auth(token, { type: 'bearer' })).status).toBe(401);
  });
  test('account deletion and session expiry invalidate issued credentials', async () => {
    const own = await session(); const token = (await mint(own.secret)).body.token;
    await query('UPDATE users SET deleted_at=NOW() WHERE id=$1', [viewer.user.id]);
    expect((await request(app).get('/v1/feed/widget').auth(token, { type: 'bearer' })).status).toBe(401);
    await query('UPDATE users SET deleted_at=NULL WHERE id=$1', [viewer.user.id]);
    await query('UPDATE refresh_tokens SET expires_at=NOW()-INTERVAL \'1 day\' WHERE id=$1', [own.id]);
    expect((await request(app).get('/v1/feed/widget').auth(token, { type: 'bearer' })).status).toBe(401);
  });
});
