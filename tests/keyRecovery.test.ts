import crypto from 'crypto';
import request from 'supertest';
import { app, pool, query, createTestUser, setupTestServer } from './helpers';
import { performanceRegistry } from '../src/performance';

setupTestServer();
const b64 = (n: number) => crypto.randomBytes(n).toString('base64');
const bundle = () => ({
  identity_key_pub: b64(33),
  signed_prekey: { id: 1, public: b64(33), signature: b64(64) },
  one_time_prekeys: [{id: 1, public: b64(33)}, {id: 2, public: b64(33)}],
  kyber_prekeys: [{id: 1, public: b64(1568), signature: b64(64)}],
});
const upload = (token: string, body: object) => request(app).post('/v1/devices/keys/upload').auth(token, {type:'bearer'}).send(body);

test('lost-reply retries are idempotent, including concurrent identical uploads', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  const responses = await Promise.all(Array.from({length: 6}, () => upload(token, keys)));
  expect(responses.map(r => r.status)).toEqual(Array(6).fill(200));
  expect((await query('SELECT COUNT(*)::int AS n FROM device_keys WHERE user_id=$1', [user.id])).rows[0].n).toBe(1);
  expect((await query('SELECT COUNT(*)::int AS n FROM one_time_prekeys WHERE user_id=$1', [user.id])).rows[0].n).toBe(2);
});

test('a retry cannot resurrect consumed prekeys or change their material', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  await upload(token, keys).expect(200);
  await query('UPDATE one_time_prekeys SET consumed_at=now() WHERE user_id=$1', [user.id]);
  await query('UPDATE kyber_prekeys SET consumed_at=now() WHERE user_id=$1', [user.id]);
  await upload(token, keys).expect(200);
  expect((await query('SELECT COUNT(*)::int AS n FROM one_time_prekeys WHERE user_id=$1 AND consumed_at IS NULL', [user.id])).rows[0].n).toBe(0);
  expect((await query('SELECT COUNT(*)::int AS n FROM kyber_prekeys WHERE user_id=$1 AND consumed_at IS NULL', [user.id])).rows[0].n).toBe(0);
  await upload(token, {...keys, kyber_prekeys: [{...keys.kyber_prekeys[0], public:b64(1568)}]}).expect(409);
});

test('a different identity or signed key is refused without replacing the active registry', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  await upload(token, keys).expect(200);
  for (const changed of [bundle(), {...keys, signed_prekey:{...keys.signed_prekey, public:b64(33)}}]) {
    const response = await upload(token, changed).expect(409);
    expect(response.body.code).toBe('key_bundle_conflict');
  }
  const stored = (await query('SELECT identity_key_pub, revoked_at FROM device_keys WHERE user_id=$1', [user.id])).rows;
  expect(stored).toHaveLength(1);
  expect(stored[0].identity_key_pub.toString('base64')).toBe(keys.identity_key_pub);
  expect(stored[0].revoked_at).toBeNull();
});

test('conflicting prekeys roll back all additions in the same upload', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  await upload(token, keys).expect(200);
  await upload(token, {...keys, one_time_prekeys:[{id:3,public:b64(33)}],
    kyber_prekeys:[{...keys.kyber_prekeys[0], signature:b64(64)}]}).expect(409);
  expect((await query('SELECT key_id FROM one_time_prekeys WHERE user_id=$1 AND key_id=3', [user.id])).rows).toHaveLength(0);
});

test('legacy ownerless material only reconciles an existing matching registry', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  await upload(token, {...keys, existing_only:true}).expect(409);
  expect((await query('SELECT id FROM device_keys WHERE user_id=$1', [user.id])).rows).toHaveLength(0);
  await upload(token, keys).expect(200);
  await upload(token, {...keys, existing_only:true, owner_user_id:user.id}).expect(200);
  await upload(token, {...keys, owner_user_id:'another-account'}).expect(403);
});

test('depleted saved bundles may reconcile, but cannot create a Kyber-less identity', async () => {
  const {token} = await createTestUser();
  const keys = bundle();
  expect((await upload(token, {...keys, kyber_prekeys:[]})).body.code).toBe('key_bundle_incomplete');
  await upload(token, keys).expect(200);
  await upload(token, {...keys, one_time_prekeys:[], kyber_prekeys:[]}).expect(200);
});

test('conflicting concurrent identities produce one success and one conflict, never a partial registry', async () => {
  const {token, user} = await createTestUser();
  const responses = await Promise.all([upload(token, bundle()), upload(token, bundle())]);
  expect(responses.map(r => r.status).sort()).toEqual([200,409]);
  expect((await query('SELECT id FROM device_keys WHERE user_id=$1', [user.id])).rows).toHaveLength(1);
});

test('revocation racing a retry leaves either a complete active registry or none', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  await upload(token, keys).expect(200);
  await Promise.all([upload(token, keys), request(app).post('/v1/devices/revoke').auth(token,{type:'bearer'}).expect(200)]);
  const active = (await query('SELECT id FROM device_keys WHERE user_id=$1 AND revoked_at IS NULL', [user.id])).rows.length;
  const prekeys = (await query('SELECT COUNT(*)::int AS n FROM one_time_prekeys WHERE user_id=$1', [user.id])).rows[0].n;
  expect(prekeys).toBe(active ? 2 : 0);
});

test('duplicate key IDs are a validation error and do not create a partial identity', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  await upload(token, {...keys, one_time_prekeys:[keys.one_time_prekeys[0], keys.one_time_prekeys[0]]}).expect(400);
  expect((await query('SELECT id FROM device_keys WHERE user_id=$1', [user.id])).rows).toHaveLength(0);
});

test('replenishment preserves consumed flags and rejects a different account or identity', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  await upload(token, keys).expect(200);
  await query('UPDATE one_time_prekeys SET consumed_at=now() WHERE user_id=$1 AND key_id=1', [user.id]);
  const body = {owner_user_id:user.id, identity_key_pub:keys.identity_key_pub,
    one_time_prekeys:[keys.one_time_prekeys[0], {id:3, public:b64(33)}]};
  const replenish = (value: object) => request(app).post('/v1/devices/keys/replenish').auth(token,{type:'bearer'}).send(value);
  await replenish(body).expect(200);
  await replenish(body).expect(200);
  expect((await query('SELECT consumed_at FROM one_time_prekeys WHERE user_id=$1 AND key_id=1', [user.id])).rows[0].consumed_at).not.toBeNull();
  await replenish({...body, owner_user_id:'someone-else'}).expect(403);
  await replenish({...body, identity_key_pub:b64(33)}).expect(409);
  expect((await query('SELECT COUNT(*)::int AS n FROM one_time_prekeys WHERE user_id=$1', [user.id])).rows[0].n).toBe(3);
});

test('reconciliation does not wait on or lock prekeys being consumed by peers', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  await upload(token, keys).expect(200);
  const consuming = await pool.connect();
  try {
    await consuming.query('BEGIN');
    await consuming.query('SELECT id FROM kyber_prekeys WHERE user_id=$1 FOR UPDATE', [user.id]);
    await upload(token, keys).timeout({response: 1000}).expect(200);
  } finally {
    await consuming.query('ROLLBACK');
    consuming.release();
  }
});

test('registry writes do not block behind unrelated account foreign-key readers', async () => {
  const {token, user} = await createTestUser();
  const referencing = await pool.connect();
  try {
    await referencing.query('BEGIN');
    // PostgreSQL takes this lock for foreign-key checks on ordinary social
    // writes. Those readers must not block updates to a separate key registry.
    await referencing.query('SELECT id FROM users WHERE id=$1 FOR KEY SHARE', [user.id]);
    await upload(token, bundle()).timeout({response:1000}).expect(200);
  } finally {
    await referencing.query('ROLLBACK');
    referencing.release();
  }
});

test('maximum upload batches retain fixed timing stages without protocol values', async () => {
  const {token, user} = await createTestUser();
  const keys = {...bundle(),
    one_time_prekeys:Array.from({length:200}, (_,i) => ({id:i+1, public:b64(33)})),
    kyber_prekeys:Array.from({length:100}, (_,i) => ({id:i+1, public:b64(1568), signature:b64(64)})),
  };
  const enabled = process.env.PERFORMANCE_METRICS;
  process.env.PERFORMANCE_METRICS = '1';
  performanceRegistry.resetMetrics();
  try {
    await upload(token, keys).expect(200);
    await upload(token, keys).expect(200);
    const metric = await performanceRegistry.getSingleMetric('aside_operation_stage_seconds')!.get();
    const stages = new Set(metric.values.map(value => value.labels.stage));
    for (const stage of ['prehandler','handler','pool','lock','registry','one_time','kyber','commit']) {
      expect(stages.has(`key_upload_${stage}`)).toBe(true);
    }
    const serialized = JSON.stringify(await performanceRegistry.getMetricsAsJSON());
    for (const value of [token, user.id, keys.identity_key_pub, keys.kyber_prekeys[0].public]) {
      expect(serialized).not.toContain(value);
    }
    expect((await query('SELECT COUNT(*)::int AS n FROM one_time_prekeys WHERE user_id=$1', [user.id])).rows[0].n).toBe(200);
    expect((await query('SELECT COUNT(*)::int AS n FROM kyber_prekeys WHERE user_id=$1', [user.id])).rows[0].n).toBe(100);
  } finally {
    if (enabled === undefined) delete process.env.PERFORMANCE_METRICS;
    else process.env.PERFORMANCE_METRICS = enabled;
  }
});

test('prekey allocation bounds include consumed rows and permit repair without replacing identity', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  await upload(token, keys).expect(200);
  await query('UPDATE one_time_prekeys SET consumed_at=now() WHERE user_id=$1', [user.id]);
  await query('UPDATE kyber_prekeys SET consumed_at=now() WHERE user_id=$1', [user.id]);
  const conflict = await upload(token, {...keys, one_time_prekeys:[{id:2, public:b64(33)}]}).expect(409);
  expect(conflict.body.code).toBe('key_prekey_conflict');
  const allocation = await request(app).post('/v1/devices/keys/prekey-allocation')
    .auth(token, {type:'bearer'}).send({owner_user_id:user.id,
      identity_key_pub:keys.identity_key_pub, signed_prekey:keys.signed_prekey}).expect(200);
  expect(allocation.body).toEqual({one_time_floor:2, kyber_floor:1});
  await upload(token, {...keys, one_time_prekeys:[{id:3, public:b64(33)}],
    kyber_prekeys:[{id:2, public:b64(1568), signature:b64(64)}]}).expect(200);
  const stored = (await query('SELECT identity_key_pub, signed_prekey_pub, revoked_at FROM device_keys WHERE user_id=$1', [user.id])).rows;
  expect(stored).toHaveLength(1);
  expect(stored[0].identity_key_pub.toString('base64')).toBe(keys.identity_key_pub);
  expect(stored[0].signed_prekey_pub.toString('base64')).toBe(keys.signed_prekey.public);
  expect(stored[0].revoked_at).toBeNull();
  expect((await query('SELECT key_id FROM one_time_prekeys WHERE user_id=$1 AND consumed_at IS NULL', [user.id])).rows).toEqual([{key_id:3}]);
  expect((await query('SELECT key_id FROM kyber_prekeys WHERE user_id=$1 AND consumed_at IS NULL', [user.id])).rows).toEqual([{key_id:2}]);
});

test('allocation requires authentication, the same owner and every registered identity/signed-key field', async () => {
  const {token, user} = await createTestUser();
  const keys = bundle();
  const body = {owner_user_id:user.id, identity_key_pub:keys.identity_key_pub, signed_prekey:keys.signed_prekey};
  const allocation = (value: object) => request(app).post('/v1/devices/keys/prekey-allocation').auth(token,{type:'bearer'}).send(value);
  await request(app).post('/v1/devices/keys/prekey-allocation').send(body).expect(401);
  await allocation(body).expect(409);
  await upload(token, keys).expect(200);
  for (const owner_user_id of [undefined, 'another-account']) await allocation({...body, owner_user_id}).expect(403);
  await allocation({...body, identity_key_pub:b64(33)}).expect(409);
  for (const signed_prekey of [
    {...keys.signed_prekey, id:2}, {...keys.signed_prekey, public:b64(33)},
    {...keys.signed_prekey, signature:b64(64)},
  ]) await allocation({...body, signed_prekey}).expect(409);
  await allocation({...body, signed_prekey:{...keys.signed_prekey, id:-1}}).expect(400);
  await allocation(body).expect(200, {one_time_floor:2, kyber_floor:1});
  expect((await query('SELECT COUNT(*)::int AS n FROM one_time_prekeys WHERE user_id=$1', [user.id])).rows[0].n).toBe(2);
  await request(app).post('/v1/devices/revoke').auth(token,{type:'bearer'}).expect(200);
  await allocation(body).expect(409);
});
