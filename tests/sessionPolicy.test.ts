import crypto from 'crypto';
import jwt from 'jsonwebtoken';
import request from 'supertest';
import { app, query, createTestUser, setupTestServer } from './helpers';
import { config } from '../src/config';
import { generateRefreshToken } from '../src/middleware/auth';
import { newSessionCredential, refreshSession } from '../src/services/refreshSession';

setupTestServer();
const nonce = () => crypto.randomBytes(32).toString('base64url');
const hash = (s: string) => crypto.createHash('sha256').update(s).digest('hex');

async function fixture(legacy = false) {
  const { user, token: access } = await createTestUser();
  const id = crypto.randomUUID();
  const token = legacy ? generateRefreshToken(user.id) : newSessionCredential(id);
  await query(`INSERT INTO refresh_tokens(id,user_id,token_hash,expires_at,rotation_enabled)
    VALUES($1,$2,$3,now()+INTERVAL '1 day',$4)`, [id,user.id,hash(token),!legacy]);
  return { user, access, id, token };
}
async function reason(token: string, attempt: unknown, expected: string) {
  await expect(refreshSession(token, attempt)).rejects.toMatchObject({ reason: expected });
}

test('active sessions renew beyond a year and only the idle deadline advances', async () => {
  const f = await fixture();
  await query("UPDATE refresh_tokens SET created_at=now()-INTERVAL '800 days' WHERE id=$1", [f.id]);
  const renewed = await refreshSession(f.token, nonce());
  expect(renewed.refresh_token).not.toBe(f.token);
  expect(renewed.refresh_token).toMatch(new RegExp(`^rt2\\.${f.id}\\.`));
  const row = (await query(`SELECT EXTRACT(EPOCH FROM expires_at-clock_timestamp()) AS remaining,
    EXTRACT(EPOCH FROM clock_timestamp()-created_at) AS age FROM refresh_tokens WHERE id=$1`, [f.id])).rows[0];
  expect(Number(row.remaining)).toBeGreaterThan(364 * 86400);
  expect(Number(row.remaining)).toBeLessThanOrEqual(365 * 86400);
  expect(Number(row.age)).toBeGreaterThan(799 * 86400);
  expect(jwt.decode(renewed.access_token)).toMatchObject({ userId: f.user.id });
});

test('lost reply and concurrent identical attempts return one successor', async () => {
  const f = await fixture();
  const attempt = nonce();
  const replies = await Promise.all(Array.from({length:8},()=>refreshSession(f.token,attempt)));
  expect(new Set(replies.map(r=>r.refresh_token)).size).toBe(1);
  expect((await query('SELECT * FROM refresh_token_rotations WHERE session_id=$1',[f.id])).rows).toHaveLength(1);
  // Even a delayed retry of the latest unacknowledged rotation is recoverable.
  await query("UPDATE refresh_token_rotations SET used_at=now()-INTERVAL '40 days' WHERE session_id=$1",[f.id]);
  expect((await refreshSession(f.token,attempt)).refresh_token).toBe(replies[0].refresh_token);
});

test('replaying a rotated credential with a different retry secret revokes its session', async () => {
  const f = await fixture();
  const next = await refreshSession(f.token,nonce());
  await reason(f.token,nonce(),'refresh_reused');
  await reason(next.refresh_token!,nonce(),'refresh_revoked');
});

test('acknowledged old retries do not revoke or mint credentials for a newer generation', async () => {
  const f = await fixture();
  const attempt = nonce();
  const second = await refreshSession(f.token,attempt);
  const third = await refreshSession(second.refresh_token!,nonce());
  await reason(f.token,attempt,'refresh_superseded');
  expect((await refreshSession(third.refresh_token!,nonce())).access_token).toBeTruthy();
});

test.each(['idle','revoked','deleted'] as const)('%s sessions are never resurrected', async kind => {
  const f = await fixture();
  if(kind==='idle') await query("UPDATE refresh_tokens SET expires_at=now()-INTERVAL '1 second' WHERE id=$1",[f.id]);
  if(kind==='revoked') await query('UPDATE refresh_tokens SET revoked_at=now() WHERE id=$1',[f.id]);
  if(kind==='deleted') await query('UPDATE users SET deleted_at=now() WHERE id=$1',[f.user.id]);
  await reason(f.token,nonce(),{idle:'refresh_idle_expired',revoked:'refresh_revoked',deleted:'refresh_inactive_account'}[kind]);
});

test('legacy sessions migrate without a login; unupgraded clients remain compatible', async () => {
  const f = await fixture(true);
  expect((await refreshSession(f.token,undefined)).refresh_token).toBeUndefined();
  const upgraded = await refreshSession(f.token,nonce());
  expect(upgraded.refresh_token).toMatch(/^rt2\./);
  await reason(upgraded.refresh_token!,undefined,'refresh_invalid');
});

test('a lost migration reply remains recoverable after the old JWT date', async () => {
  const f = await fixture(true);
  const attempt = nonce();
  const migrated = await refreshSession(f.token, attempt);
  const clock = jest.spyOn(Date, 'now').mockReturnValue(Date.now() + 400 * 86400000);
  try {
    expect((await refreshSession(f.token, attempt)).refresh_token).toBe(migrated.refresh_token);
  } finally { clock.mockRestore(); }
});

test('bad JWT signatures and expired legacy JWTs cannot migrate, even with a matching DB row',async()=>{
  for(const expired of [true,false]) {
    const f = await fixture(true);
    const value = jwt.sign({userId:f.user.id},expired?config.jwtRefreshSecret:'wrong-fixture-secret',
      {expiresIn:expired?-1:3600});
    await query('UPDATE refresh_tokens SET token_hash=$2 WHERE id=$1',[f.id,hash(value)]);
    await reason(value,nonce(),'refresh_invalid');
  }
});

test('logout with an acknowledged or lost-reply credential deletes the entire session',async()=>{
  const f=await fixture();
  const next=await refreshSession(f.token,nonce());
  await request(app).delete('/v1/auth/session').auth(f.access,{type:'bearer'})
    .send({refresh_token:f.token}).expect(200);
  await reason(next.refresh_token!,nonce(),'refresh_unknown');
  expect((await query('SELECT * FROM refresh_token_rotations WHERE session_id=$1',[f.id])).rows).toHaveLength(0);
});

test('malformed and unknown requests cannot revoke another session',async()=>{
  const f=await fixture();
  await reason(f.token,'invalid','refresh_invalid');
  await reason(newSessionCredential(f.id),nonce(),'refresh_unknown');
  expect((await refreshSession(f.token,nonce())).access_token).toBeTruthy();
});

test('modern login opts into rotation; access tokens remain short lived',async()=>{
  const email='rolling-session@example.test';
  await request(app).post('/v1/auth/request-otp').send({email}).expect(200);
  const response=await request(app).post('/v1/auth/verify-otp')
    .send({email,code:'123456',display_name:'Session fixture',refresh_protocol:2}).expect(200);
  expect(response.body.refresh_token).toMatch(/^rt2\./);
  const access=jwt.decode(response.body.access_token) as jwt.JwtPayload;
  expect(access.exp!-access.iat!).toBe(900);
});
