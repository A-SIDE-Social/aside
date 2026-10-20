import request from 'supertest';
import fs from 'fs';
import path from 'path';
import { app } from '../src/app';
import { query, pool } from '../src/db/pool';
import { generateAccessToken } from '../src/middleware/auth';
import { processMediaDeletionQueue } from '../src/services/mediaDeletion';
import * as storage from '../src/storage';

// This suite must only run against a disposable local database.
const database = new URL(process.env.DATABASE_URL || 'postgres://invalid/invalid');
if (!['127.0.0.1', 'localhost'].includes(database.hostname) ||
    !database.pathname.endsWith('_tests')) throw new Error('Use a disposable local _tests database');

const audio = Buffer.alloc(32);
audio.write('ftyp', 4); audio.write('M4A ', 8);
let owner: string, friend: string, outsider: string;
const token = (id: string) => generateAccessToken(id);
async function user(name: string) {
  const { rows } = await query(`INSERT INTO users(username, display_name, email)
    VALUES ($1, $1, $2) RETURNING id`, [name, `${name}@example.test`]);
  return rows[0].id as string;
}
async function upload(id = owner, duration = '12000', bytes = audio) {
  return request(app).post('/v1/posts/voice-captions')
    .auth(token(id), { type: 'bearer' }).set('Content-Type', 'audio/mp4')
    .set('X-Voice-Duration-Ms', duration).send(bytes);
}
async function post(voiceId: string, id = owner, groupIds?: string[]) {
  return request(app).post('/v1/posts').auth(token(id), { type: 'bearer' })
    .send({ caption: 'A photo with a voice caption',
      media: [{ key: 'photo.jpg', media_type: 'photo', position: 0 }],
      voice_caption_id: voiceId, ...(groupIds ? { group_ids: groupIds } : {}) });
}

beforeAll(async () => {
  await query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  const directory = path.join(__dirname, '../src/db/migrations');
  for (const file of fs.readdirSync(directory).filter(f => f.endsWith('.sql')).sort()) {
    await query(fs.readFileSync(path.join(directory, file), 'utf8'));
  }
  owner = await user('voice-owner'); friend = await user('voice-friend'); outsider = await user('voice-outsider');
  await query('INSERT INTO follows(follower_id, followee_id) VALUES ($1, $2), ($2, $1)', [owner, friend]);
});
afterAll(async () => {
  await query('DELETE FROM post_voice_captions');
  await processMediaDeletionQueue();
  await pool.end();
});

test('voice upload requires authentication', async () => {
  expect((await request(app).post('/v1/posts/voice-captions').send(audio)).status).toBe(401);
});
test.each(['0', '-1', '60001', '1.2', 'invalid'])('rejects invalid duration %s', async duration => {
  expect((await upload(owner, duration)).status).toBe(400);
});
test('rejects invalid audio and excessive size', async () => {
  expect((await upload(owner, '12000', Buffer.from('not an audio file'))).status).toBe(400);
  expect((await upload(owner, '12000', Buffer.alloc(2097153))).status).toBe(413);
});
test('only the post audience can fetch audio, and metadata has no storage URL', async () => {
  const saved = await upload();
  expect(saved.status).toBe(201);
  expect(saved.body.voice_caption).toEqual({ id: expect.any(String), duration_ms: 12000 });
  const created = await post(saved.body.voice_caption.id);
  expect(created.status).toBe(201);
  expect(created.body.post.voice_caption_duration_ms).toBe(12000);
  expect(JSON.stringify(created.body)).not.toContain('voice-captions/');
  const id = created.body.post.id;
  const fetchAudio = (viewer: string) => request(app).get(`/v1/posts/${id}/voice-caption`).auth(token(viewer), { type: 'bearer' });
  expect((await fetchAudio(owner)).status).toBe(200);
  const allowed = await fetchAudio(friend);
  expect(allowed.status).toBe(200);
  expect(allowed.headers['cache-control']).toBe('private, no-store');
  expect(allowed.body).toEqual(audio);
  expect((await fetchAudio(outsider)).status).toBe(404);
  expect((await request(app).get(`/v1/posts/${id}/voice-caption`)).status).toBe(401);
  // The generic dev upload route must not expose private audio by filename.
  expect((await request(app).get(`/v1/posts/upload/${saved.body.voice_caption.id}.m4a`)).status).toBe(404);
  await query('DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2', [friend, owner]);
  expect((await fetchAudio(friend)).status).toBe(404);
  await query('INSERT INTO follows(follower_id, followee_id) VALUES ($1, $2)', [friend, owner]);
});
test('cannot steal or reuse another recording; transaction rolls back', async () => {
  const saved = await upload();
  expect((await post(saved.body.voice_caption.id, outsider)).status).toBe(400);
  expect((await post(saved.body.voice_caption.id)).status).toBe(201);
  expect((await post(saved.body.voice_caption.id)).status).toBe(400);
});
test('malformed reservation IDs fail as a bad request', async () => {
  expect((await post('-'.repeat(36))).status).toBe(400);
});
test('account deletion during upload cannot leave an unqueued object', async () => {
  const disposable = await user('voice-upload-deletion');
  const originalPut = storage.putVoiceCaption;
  const writing = jest.spyOn(storage, 'putVoiceCaption').mockImplementationOnce(async (key, bytes) => {
    await query('DELETE FROM users WHERE id = $1', [disposable]);
    await processMediaDeletionQueue();
    await originalPut(key, bytes);
  });
  try {
    const result = await upload(disposable);
    expect(result.status).toBe(404);
    const queued = await query('SELECT object_key FROM media_deletion_queue WHERE object_key LIKE $1', ['voice-captions/%']);
    expect(queued.rowCount).toBe(1);
    expect(await storage.readVoiceCaption(queued.rows[0].object_key)).toEqual(audio);
    await processMediaDeletionQueue();
  } finally {
    writing.mockRestore();
  }
});
test('history limits and expiry apply to voice downloads too', async () => {
  const saved = await upload();
  const created = await post(saved.body.voice_caption.id);
  const id = created.body.post.id;
  const fetchAudio = (viewer: string) => request(app).get(`/v1/posts/${id}/voice-caption`)
    .auth(token(viewer), { type: 'bearer' });
  await query("UPDATE posts SET created_at = NOW() - INTERVAL '40 days' WHERE id = $1", [id]);
  await query("UPDATE users SET subscription_status = 'free', trial_ends_at = NOW() - INTERVAL '1 day' WHERE id = $1", [friend]);
  expect((await fetchAudio(friend)).status).toBe(404);
  expect((await fetchAudio(owner)).status).toBe(200);
  await query("UPDATE users SET subscription_status = 'active' WHERE id = $1", [friend]);
  expect((await fetchAudio(friend)).status).toBe(200);
  await query("UPDATE posts SET expires_at = NOW() - INTERVAL '1 hour' WHERE id = $1", [id]);
  expect((await fetchAudio(friend)).status).toBe(404);
  expect((await fetchAudio(owner)).status).toBe(200);
});
test('rejects voice captions on text-only and video-only posts', async () => {
  const saved = await upload();
  for (const media of [[], [{ key: 'movie.mp4', media_type: 'video', position: 0 }]]) {
    const response = await request(app).post('/v1/posts').auth(token(owner), { type: 'bearer' })
      .send({ caption: 'No photo', media, voice_caption_id: saved.body.voice_caption.id });
    expect(response.status).toBe(400);
  }
});
test('a mutual connection excluded from a private list cannot fetch audio', async () => {
  const { rows } = await query('INSERT INTO groups(user_id, name) VALUES ($1, $2) RETURNING id', [owner, 'Close friends']);
  await query('INSERT INTO group_members(group_id, member_user_id) VALUES ($1, $2)', [rows[0].id, friend]);
  const saved = await upload();
  const created = await post(saved.body.voice_caption.id, owner, [rows[0].id]);
  expect(created.status).toBe(201);
  // A different mutual connection is still outside the immutable list audience.
  await query('INSERT INTO follows(follower_id, followee_id) VALUES ($1, $2), ($2, $1)', [owner, outsider]);
  expect((await request(app).get(`/v1/posts/${created.body.post.id}/voice-caption`)
    .auth(token(outsider), { type: 'bearer' })).status).toBe(404);
});
test('post and account deletion enqueue private audio for durable cleanup', async () => {
  const saved = await upload(); const created = await post(saved.body.voice_caption.id);
  expect((await request(app).delete(`/v1/posts/${created.body.post.id}`).auth(token(owner), { type: 'bearer' })).status).toBe(200);
  let queued = await query('SELECT 1 FROM media_deletion_queue WHERE object_key = $1', [`voice-captions/${saved.body.voice_caption.id}.m4a`]);
  expect(queued.rowCount).toBe(1);
  const disposable = await user('voice-deletion');
  const other = await upload(disposable);
  await query('DELETE FROM users WHERE id = $1', [disposable]);
  queued = await query('SELECT 1 FROM media_deletion_queue WHERE object_key = $1', [`voice-captions/${other.body.voice_caption.id}.m4a`]);
  expect(queued.rowCount).toBe(1);
});
test('abandoned uploads expire after a day', async () => {
  const saved = await upload();
  await query("UPDATE post_voice_captions SET created_at = NOW() - INTERVAL '25 hours' WHERE id = $1", [saved.body.voice_caption.id]);
  await processMediaDeletionQueue();
  expect((await query('SELECT 1 FROM post_voice_captions WHERE id = $1', [saved.body.voice_caption.id])).rowCount).toBe(0);
});
