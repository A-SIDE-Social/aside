import crypto from 'crypto';
import jwt from 'jsonwebtoken';
import request from 'supertest';
import { app, query, createTestUser, createMutualFollow, setupTestServer } from './helpers';
import { config } from '../src/config';
import { verifyEmailOtp } from '../src/services/emailOtp';

setupTestServer();
const b64 = (n: number) => crypto.randomBytes(n).toString('base64');
const bundle = () => ({
  identity_key_pub: b64(33), signed_prekey: { id: 1, public: b64(33), signature: b64(64) },
  one_time_prekeys: [{ id: 1, public: b64(33) }],
  kyber_prekeys: [{ id: 1, public: b64(1568), signature: b64(64) }],
});
async function session(userId: string) {
  const id = crypto.randomUUID();
  const credential = b64(32);
  await query(`INSERT INTO refresh_tokens(id,user_id,token_hash,expires_at)
    VALUES($1,$2,$3,now()+interval '1 year')`,
  [id, userId, crypto.createHash('sha256').update(credential).digest('hex')]);
  return { id, credential };
}
async function fixture() {
  const { user, token } = await createTestUser();
  const email = `${user.id}@example.test`;
  await query('UPDATE users SET email=$2 WHERE id=$1', [user.id, email]);
  const old = bundle();
  await request(app).post('/v1/devices/keys/upload').auth(token, { type: 'bearer' }).send(old).expect(200);
  const current = await session(user.id);
  const stale = await session(user.id);
  const target = { ...bundle(), owner_user_id: user.id, refresh_token: current.credential };
  const post = (path: string, body: object) => request(app).post(`/v1/devices/${path}`).auth(token, { type: 'bearer' }).send(body);
  const response = await post('keys/recovery/request', target).expect(200);
  const confirmation = { ...target, ticket: response.body.ticket, code: '123456' };
  return { user, token, email, old, current, stale, target, confirmation, post };
}

test('device-change codes cannot sign in, and login codes cannot confirm a device change', async () => {
  const f = await fixture();
  await expect(verifyEmailOtp(f.email, '123456', async () => true)).rejects.toMatchObject({ code: 'otp_invalid' });
  await query("UPDATE email_otps SET purpose='login' WHERE email=$1", [f.email]);
  await f.post('keys/recovery/confirm', f.confirmation).expect(400);
  await query("UPDATE email_otps SET purpose='messaging-device-change' WHERE email=$1", [f.email]);
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
});

test('explicit email confirmation replaces the registry atomically and binds the new login', async () => {
  const f = await fixture();
  let rows = (await query('SELECT identity_key_pub FROM device_keys WHERE user_id=$1 AND revoked_at IS NULL', [f.user.id])).rows;
  expect(rows[0].identity_key_pub.toString('base64')).toBe(f.old.identity_key_pub);
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
  rows = (await query('SELECT identity_key_pub, owner_session_id FROM device_keys WHERE user_id=$1 AND revoked_at IS NULL', [f.user.id])).rows;
  expect(rows).toHaveLength(1);
  expect(rows[0].identity_key_pub.toString('base64')).toBe(f.target.identity_key_pub);
  expect(rows[0].owner_session_id).toBe(f.current.id);
  expect((await query('SELECT COUNT(*)::int n FROM email_otps WHERE email=$1', [f.email])).rows[0].n).toBe(0);
});

test('a transfer advances encrypted group epochs once, including lost-response retries', async () => {
  const f = await fixture();
  const group = (await query("INSERT INTO conversations(conversation_type,name,is_e2ee) VALUES('group','Transfer test',true) RETURNING id", [])).rows[0];
  await query('INSERT INTO conversation_members(conversation_id,user_id) VALUES($1,$2)', [group.id, f.user.id]);
  await f.post('keys/recovery/confirm', { ...f.confirmation, code: '000000' }).expect(400);
  expect((await query('SELECT epoch FROM conversations WHERE id=$1', [group.id])).rows[0].epoch).toBe(0);
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
  expect((await query('SELECT epoch FROM conversations WHERE id=$1', [group.id])).rows[0].epoch).toBe(1);
});

test('identity checks are private to eligible peers and do not consume prekeys', async () => {
  const f = await fixture();
  const peer = await createTestUser();
  const get = () => request(app).get(`/v1/users/${f.user.id}/key-identity`).auth(peer.token, { type: 'bearer' });
  await get().expect(403);
  await createMutualFollow(f.user.id, peer.user.id);
  const before = await get().expect(200);
  expect(before.headers['cache-control']).toBe('private, no-store');
  expect(before.body).toEqual({ identity_key_pub: f.old.identity_key_pub });
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
  expect((await get().expect(200)).body).toEqual({ identity_key_pub: f.target.identity_key_pub });
  expect((await query('SELECT key_id FROM kyber_prekeys WHERE user_id=$1 AND consumed_at IS NULL', [f.user.id])).rows).toHaveLength(1);
});

test('a peer fetch racing transfer never mixes one identity with another device’s prekeys', async () => {
  const f = await fixture();
  const peer = await createTestUser();
  await createMutualFollow(f.user.id, peer.user.id);
  const [fetched, moved] = await Promise.all([
    request(app).get(`/v1/users/${f.user.id}/keybundle`).auth(peer.token, { type: 'bearer' }),
    f.post('keys/recovery/confirm', f.confirmation),
  ]);
  expect(moved.status).toBe(200);
  expect(fetched.status).toBe(200);
  const expected = fetched.body.identity_key_pub === f.old.identity_key_pub ? f.old : f.target;
  expect(fetched.body.identity_key_pub).toBe(expected.identity_key_pub);
  expect(fetched.body.kyber_prekey.public).toBe(expected.kyber_prekeys[0].public);
  expect(fetched.body.one_time_prekey.public).toBe(expected.one_time_prekeys[0].public);
});

test('legacy and stale logout cannot revoke the transferred registration or delete prekeys', async () => {
  const f = await fixture();
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
  for (const body of [{}, { refresh_token: f.stale.credential }, { refresh_token: 'invalid' }]) {
    await f.post('revoke', body).expect(200);
  }
  expect((await query('SELECT id FROM device_keys WHERE user_id=$1 AND revoked_at IS NULL', [f.user.id])).rows).toHaveLength(1);
  expect((await query('SELECT key_id FROM kyber_prekeys WHERE user_id=$1', [f.user.id])).rows).toHaveLength(1);
  await f.post('revoke', { refresh_token: f.current.credential }).expect(200);
  expect((await query('SELECT id FROM device_keys WHERE user_id=$1 AND revoked_at IS NULL', [f.user.id])).rows).toHaveLength(0);
});

test('deleting the owning login does not turn the registration back into a legacy one', async () => {
  const f = await fixture();
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
  await query('DELETE FROM refresh_tokens WHERE id=$1', [f.current.id]);
  await f.post('revoke', {}).expect(200);
  await f.post('keys/upload', { ...f.target, refresh_token: f.stale.credential }).expect(409);
  expect((await query('SELECT owner_session_id FROM device_keys WHERE user_id=$1 AND revoked_at IS NULL', [f.user.id])).rows[0].owner_session_id).toBe(f.current.id);
});

test('wrong guesses are bounded and never replace the old identity', async () => {
  const f = await fixture();
  for (let i = 0; i < 5; i++) await f.post('keys/recovery/confirm', { ...f.confirmation, code: '000000' }).expect(400);
  await f.post('keys/recovery/confirm', f.confirmation).expect(429);
  expect((await query('SELECT identity_key_pub FROM device_keys WHERE user_id=$1 AND revoked_at IS NULL', [f.user.id])).rows[0].identity_key_pub.toString('base64')).toBe(f.old.identity_key_pub);
});

test('lost replies and concurrent retries never resurrect consumed prekeys', async () => {
  const f = await fixture();
  const responses = await Promise.all(Array.from({ length: 5 }, () => f.post('keys/recovery/confirm', f.confirmation)));
  expect(responses.map(r => r.status)).toEqual(Array(5).fill(200));
  await query('UPDATE one_time_prekeys SET consumed_at=now() WHERE user_id=$1', [f.user.id]);
  await query('UPDATE kyber_prekeys SET consumed_at=now() WHERE user_id=$1', [f.user.id]);
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
  expect((await query('SELECT key_id FROM one_time_prekeys WHERE user_id=$1 AND consumed_at IS NULL', [f.user.id])).rows).toHaveLength(0);
  expect((await query('SELECT id FROM device_keys WHERE user_id=$1', [f.user.id])).rows).toHaveLength(2);
});

test('a changed target, account, ticket, or login is refused without consuming the code', async () => {
  const f = await fixture();
  for (const body of [
    { ...f.confirmation, identity_key_pub: b64(33) },
    { ...f.confirmation, owner_user_id: crypto.randomUUID() },
    { ...f.confirmation, ticket: f.confirmation.ticket + 'x' },
    { ...f.confirmation, refresh_token: f.stale.credential },
  ]) {
    expect((await f.post('keys/recovery/confirm', body)).status).toBeGreaterThanOrEqual(400);
  }
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
});

test('expiry and another registry change make an uncompleted ticket stale', async () => {
  const f = await fixture();
  const payload = jwt.decode(f.confirmation.ticket) as jwt.JwtPayload;
  const key = crypto.createHmac('sha256', config.jwtSecret).update('messaging-device-recovery-v1').digest();
  await f.post('keys/recovery/confirm', { ...f.confirmation,
    ticket: jwt.sign({ ...payload, exp: 1 }, key, { algorithm: 'HS256' }) }).expect(409);
  await f.post('revoke', {}).expect(200);
  await f.post('keys/upload', bundle()).expect(200);
  await f.post('keys/recovery/confirm', f.confirmation).expect(409);
});

test('a completed ticket cannot undo a later revoke or resurrect its registration', async () => {
  const f = await fixture();
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
  await f.post('revoke', { refresh_token: f.current.credential }).expect(200);
  await f.post('keys/recovery/confirm', f.confirmation).expect(409);
});

test('old-session uploads, replenishment and signed-key rotation cannot mutate recovered keys', async () => {
  const f = await fixture();
  await f.post('keys/recovery/confirm', f.confirmation).expect(200);
  const stale = { ...f.target, refresh_token: f.stale.credential };
  await f.post('keys/upload', stale).expect(409);
  await f.post('keys/replenish', { one_time_prekeys: [{ id: 99, public: b64(33) }] }).expect(409);
  await f.post('keys/rotate-signed', { signed_prekey: f.old.signed_prekey }).expect(409);
  await f.post('keys/upload', f.target).expect(200);
  await f.post('keys/replenish', { refresh_token: f.current.credential, one_time_prekeys: [{ id: 99, public: b64(33) }] }).expect(200);
  await f.post('keys/rotate-signed', { refresh_token: f.current.credential, signed_prekey: f.target.signed_prekey }).expect(200);
});

test('rotated current credentials retain the stable session binding; stale hashes do not', async () => {
  const f = await fixture();
  const successor = b64(32);
  await query('UPDATE refresh_tokens SET token_hash=$2 WHERE id=$1', [f.current.id, crypto.createHash('sha256').update(successor).digest('hex')]);
  const rejected = await f.post('keys/recovery/confirm', f.confirmation).expect(409);
  expect(rejected.body.code).toBe('key_session_changed');
  await f.post('keys/recovery/confirm', { ...f.confirmation, refresh_token: successor }).expect(200);
});

test('code issuance needs a live owned login, bounded valid keys and the correct account', async () => {
  const f = await fixture();
  await f.post('keys/recovery/request', { ...f.target, refresh_token: f.stale.credential, owner_user_id: 'another-account' }).expect(403);
  await f.post('keys/recovery/request', { ...f.target, refresh_token: 'invalid' }).expect(409);
  await f.post('keys/recovery/request', { ...f.target, kyber_prekeys: [] }).expect(400);
  await f.post('keys/recovery/request', f.target).expect(429);
  await query('UPDATE refresh_tokens SET expires_at=now()-interval \'1 day\' WHERE id=$1', [f.current.id]);
  await f.post('keys/recovery/confirm', f.confirmation).expect(409);
});

test('changed email and revoked login cannot complete an outstanding confirmation', async () => {
  const f = await fixture();
  await query('UPDATE users SET email=$2 WHERE id=$1', [f.user.id, `${crypto.randomUUID()}@example.test`]);
  await f.post('keys/recovery/confirm', f.confirmation).expect(409);
  await query('UPDATE users SET email=$2 WHERE id=$1', [f.user.id, f.email]);
  await query('UPDATE refresh_tokens SET revoked_at=now() WHERE id=$1', [f.current.id]);
  await f.post('keys/recovery/confirm', f.confirmation).expect(409);
});
