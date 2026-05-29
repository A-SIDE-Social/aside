import request from 'supertest';
import http from 'http';
import crypto from 'crypto';
import { app } from '../src/app';
import { pool, query } from '../src/db/pool';
import { initSocket } from '../src/socket';
import { generateAccessToken } from '../src/middleware/auth';
import { SYSTEM_USER_EMAIL } from '../src/constants';
import fs from 'fs';
import path from 'path';

let server: http.Server;

// Helper to create a user directly in the DB and get a token
async function createTestUser(overrides: Partial<{
  display_name: string;
  email: string;
  phone_e164: string;
  subscription_status: string;
}> = {}) {
  const autoUsername = `u${Math.random().toString(36).slice(2, 18)}`;
  const displayName = overrides.display_name || `Test User ${Math.random().toString(36).slice(2, 6)}`;
  const email = overrides.email || `test${Math.random().toString(36).slice(2, 10)}@test.com`;
  const { rows } = await query(
    `INSERT INTO users (username, display_name, email, phone_e164, subscription_status)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING *`,
    [
      autoUsername,
      displayName,
      email,
      overrides.phone_e164 || null,
      overrides.subscription_status || 'free',
    ],
  );
  const user = rows[0];
  const token = generateAccessToken(user.id);
  return { user, token };
}

// Helper to create mutual follow between two users
async function createMutualFollow(userAId: string, userBId: string) {
  await query(
    `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2), ($2, $1)
     ON CONFLICT DO NOTHING`,
    [userAId, userBId],
  );
}

beforeAll(async () => {
  // Create test database schema — apply all migrations
  await query(`
    DROP SCHEMA public CASCADE;
    CREATE SCHEMA public;
    GRANT ALL ON SCHEMA public TO public;
  `);

  const migrationsDir = path.join(__dirname, '../src/db/migrations');
  const migrationFiles = fs.readdirSync(migrationsDir).filter(f => f.endsWith('.sql')).sort();
  for (const file of migrationFiles) {
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

// ==================== AUTH ====================
describe('Auth', () => {
  test('POST /v1/auth/request-otp sends OTP', async () => {
    const res = await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'test1000@test.com' });
    expect(res.status).toBe(200);
    expect(res.body.message).toBe('OTP sent');
  });

  test('POST /v1/auth/request-otp rejects missing email', async () => {
    const res = await request(app)
      .post('/v1/auth/request-otp')
      .send({});
    expect(res.status).toBe(400);
  });

  test('POST /v1/auth/verify-otp fails with wrong code', async () => {
    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'test1001@test.com' });

    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({ email: 'test1001@test.com', code: '000000' });
    expect(res.status).toBe(401);
  });

  test('POST /v1/auth/verify-otp requires display_name for new user', async () => {
    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'test1002@test.com' });

    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({ email: 'test1002@test.com', code: '123456' });
    expect(res.status).toBe(400);
    expect(res.body.error).toContain('display_name');
  });

  test('OTP is not consumed when display_name is missing for new user', async () => {
    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'otp-preserve@test.com' });

    // First verify without display_name - should fail but preserve OTP
    const res1 = await request(app)
      .post('/v1/auth/verify-otp')
      .send({ email: 'otp-preserve@test.com', code: '123456' });
    expect(res1.status).toBe(400);

    // Second verify with same code should still work (OTP not consumed)
    const res2 = await request(app)
      .post('/v1/auth/verify-otp')
      .send({ email: 'otp-preserve@test.com', code: '123456' });
    expect(res2.status).toBe(400); // still needs display_name, but OTP is valid
    expect(res2.body.error).toContain('display_name');
  });

  test('Auth response contains access_token, refresh_token, and user', async () => {
    const { user: inviter } = await createTestUser({ email: 'inviter-shape@test.com' });
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, 'testshape00001', 'pending', NOW() + INTERVAL '7 days')
       RETURNING *`,
      [inviter.id],
    );

    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'shape-test@test.com' });

    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email: 'shape-test@test.com',
        code: '123456',
        invite_code: 'testshape00001',
        display_name: 'Shape Test',
      });

    expect(res.status).toBe(200);
    // Verify snake_case keys (not camelCase)
    expect(typeof res.body.access_token).toBe('string');
    expect(typeof res.body.refresh_token).toBe('string');
    expect(res.body.token).toBeUndefined();
    expect(res.body.refreshToken).toBeUndefined();
    expect(res.body.user).toBeDefined();
    expect(res.body.user.id).toBeDefined();
    expect(res.body.user.display_name).toBe('Shape Test');
  });

  test('Public endpoints are not blocked by auth middleware', async () => {
    // OTP request should work without auth
    const otpRes = await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'public-test@test.com' });
    expect(otpRes.status).toBe(200);

    // Health check
    const healthRes = await request(app).get('/health');
    expect(healthRes.status).toBe(200);

    // Invite validation should work without auth
    const validateRes = await request(app)
      .get('/v1/invites/validate/nonexistent');
    expect(validateRes.status).toBe(200);
    expect(validateRes.body.valid).toBe(false);
  });

  test('Full registration flow with invite', async () => {
    // Create an inviter user
    const { user: inviter, token: inviterToken } = await createTestUser({
      email: 'inviter-reg@test.com',
    });

    // Create an invite for the inviter
    const { rows: inviteRows } = await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, 'testcode00001', 'pending', NOW() + INTERVAL '30 days')
       RETURNING *`,
      [inviter.id],
    );

    // Request OTP
    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'newuser-reg@test.com' });

    // Verify OTP with registration data
    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email: 'newuser-reg@test.com',
        code: '123456',
        invite_code: 'testcode00001',
        display_name: 'New User',
      });

    expect(res.status).toBe(200);
    expect(res.body.access_token).toBeDefined();
    expect(res.body.refresh_token).toBeDefined();
    expect(res.body.user.display_name).toBe('New User');

    // Verify mutual follow was created
    const { rows: follows } = await query(
      'SELECT * FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [res.body.user.id, inviter.id],
    );
    expect(follows.length).toBe(1);

    // Verify invite was marked as used
    const { rows: usedInvites } = await query(
      "SELECT * FROM invites WHERE code = 'testcode00001'",
    );
    expect(usedInvites[0].status).toBe('used');
    expect(usedInvites[0].used_by_user_id).toBe(res.body.user.id);

    // Verify new user got 25 invite codes
    const { rows: newInvites } = await query(
      'SELECT * FROM invites WHERE created_by_user_id = $1',
      [res.body.user.id],
    );
    expect(newInvites.length).toBe(25);
  });

  // Regression: an invite code that had been "shared" via the in-app
  // Share button was rejected at signup. Sharing flips status from
  // 'pending' → 'sent' (see src/routes/invites.ts PATCH /:id). The
  // signup validator only accepted 'pending', so every shared code
  // was unredeemable for new signups — silently breaking the entire
  // share-code-to-friend flow. The friend-add path (POST
  // /v1/invites/redeem for existing users) had always accepted both,
  // so this signup-only failure was easy to miss. Fix accepts both
  // statuses; this test locks that in.
  test('Signup accepts a "sent" invite code (not just "pending")', async () => {
    const { user: inviter } = await createTestUser({
      email: 'sent-status-inviter@test.com',
    });

    // Create an invite already in 'sent' status — i.e. the inviter
    // tapped Share on it before the friend tried to sign up.
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, 'sentcode00001', 'sent', NOW() + INTERVAL '30 days')`,
      [inviter.id],
    );

    const email = 'sent-status-invitee@test.com';
    await request(app).post('/v1/auth/request-otp').send({ email });
    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email,
        code: '123456',
        invite_code: 'sentcode00001',
        display_name: 'Sent Status Invitee',
      });

    expect(res.status).toBe(200);
    expect(res.body.user.display_name).toBe('Sent Status Invitee');

    // Invite must be marked 'used', not stuck at 'sent'.
    const { rows: after } = await query(
      "SELECT status, used_by_user_id FROM invites WHERE code = 'sentcode00001'",
    );
    expect(after[0].status).toBe('used');
    expect(after[0].used_by_user_id).toBe(res.body.user.id);

    // Mutual follow must be created — the share-code-to-friend flow's
    // whole point is the auto-connect.
    const { rows: follows } = await query(
      'SELECT * FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [res.body.user.id, inviter.id],
    );
    expect(follows.length).toBe(1);
  });

  // Regression: a real user reported landing in the app with 0 invite
  // codes after being added via an inviter. Likely cause was stale state
  // from an earlier app version where allocation was on-demand. The
  // current code allocates `LIMITS.maxInvites` on every fresh signup;
  // these tests lock that in across multiple consecutive signups so we
  // never silently regress to "0 codes for new users."
  test('Every fresh signup yields exactly LIMITS.maxInvites codes', async () => {
    const { user: inviter } = await createTestUser({
      email: 'multi-inviter@test.com',
    });
    // Pre-create enough invite codes for 5 invitees
    const codes = ['multi-1abc01', 'multi-2def02', 'multi-3ghi03', 'multi-4jkl04', 'multi-5mno05'];
    for (const c of codes) {
      await query(
        `INSERT INTO invites (created_by_user_id, code, status, expires_at)
         VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
        [inviter.id, c],
      );
    }

    for (let i = 0; i < codes.length; i++) {
      const email = `multi-invitee-${i}@test.com`;
      await request(app).post('/v1/auth/request-otp').send({ email });
      const res = await request(app)
        .post('/v1/auth/verify-otp')
        .send({
          email,
          code: '123456',
          invite_code: codes[i],
          display_name: `Invitee ${i}`,
        });
      expect(res.status).toBe(200);
      const { rows } = await query(
        'SELECT COUNT(*)::int AS c FROM invites WHERE created_by_user_id = $1',
        [res.body.user.id],
      );
      expect(rows[0].c).toBe(25);
    }
  });

  // Regression: a signup with an INVALID invite code used to leave a
  // half-created user row that the next attempt would short-circuit
  // past, leaving them with zero allocated codes (migration 015
  // backfilled the affected rows in prod). The old flow:
  //   1. INSERT INTO users (no transaction)
  //   2. SELECT invite by code → 0 rows → throw 400
  //   3. Return 400 to the client; user row left behind in the DB
  //   4. User taps "try again" → resolveUser hits existingUsers branch
  //      → returns the bare row WITHOUT running the 25-code allocation
  //   5. User is now in the app with 0 invite codes, no recovery path
  // The fix wraps signup in a BEGIN/COMMIT so the invalid-code throw
  // rolls back the user row too. This test asserts that.
  test('Invalid invite code does NOT leave a partial user in the DB', async () => {
    const email = 'partial-user@test.com';
    await request(app).post('/v1/auth/request-otp').send({ email });

    // Submit with a bogus invite code — should fail.
    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email,
        code: '123456',
        invite_code: 'totally-bogus-code',
        display_name: 'Partial User',
      });
    expect(res.status).toBe(400);

    // Critical: no user row should exist after that failed attempt.
    // Pre-fix, this row would persist and short-circuit the next signup.
    const { rows: leftover } = await query(
      'SELECT id FROM users WHERE email = $1 AND deleted_at IS NULL',
      [email],
    );
    expect(leftover.length).toBe(0);

    // And a clean retry with a valid code should succeed and yield 25 codes.
    const { user: inviter } = await createTestUser({ email: 'partial-inviter@test.com' });
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, 'partial-good01', 'pending', NOW() + INTERVAL '30 days')`,
      [inviter.id],
    );
    await request(app).post('/v1/auth/request-otp').send({ email });
    const retry = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email,
        code: '123456',
        invite_code: 'partial-good01',
        display_name: 'Partial User',
      });
    expect(retry.status).toBe(200);
    const { rows: retryInvites } = await query(
      'SELECT COUNT(*)::int AS c FROM invites WHERE created_by_user_id = $1',
      [retry.body.user.id],
    );
    expect(retryInvites[0].c).toBe(25);
  });

  // Defensive belt-and-suspenders: even if a 12-char UUID-prefix
  // collision ever does fire, allocateInvitesForUser must NOT leave the
  // user with fewer than `count` codes. The retry path is exercised by
  // injecting a generator that returns a colliding code on the first
  // call, then random codes thereafter.
  test('allocateInvitesForUser recovers from a forced code collision', async () => {
    const { allocateInvitesForUser } = await import('../src/routes/auth');
    const { user } = await createTestUser({ email: 'collision-defense@test.com' });

    const collidingCode = 'collide00001';
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
      [user.id, collidingCode],
    );

    let calls = 0;
    const codeGen = () => {
      calls++;
      // First call collides; subsequent calls are unique.
      if (calls === 1) return collidingCode;
      return `nocoll${Math.random().toString(36).slice(2, 8)}`;
    };

    await allocateInvitesForUser(user.id, 5, codeGen);

    // 1 pre-existing + 5 newly-allocated = 6 total. The retry on collision
    // means we still got a full 5 new codes despite the first attempt
    // hitting the pre-inserted row.
    const { rows } = await query(
      'SELECT COUNT(*)::int AS c FROM invites WHERE created_by_user_id = $1',
      [user.id],
    );
    expect(rows[0].c).toBe(6);
    expect(calls).toBeGreaterThanOrEqual(6); // at least 1 collision + 5 successes
  });

  // Build 34: verify-otp response now resolves avatar_url through
  // resolveMediaUrl. Previously it returned the raw S3 key, which
  // made fresh-device logins render the initials fallback (because
  // the mobile Avatar widget fed a bare UUID to CachedNetworkImage,
  // which treated it as an invalid URL and fell back to the error
  // widget). The bug only surfaced on first login — initialize()
  // calls GET /users/me which did resolve correctly, so force-quit
  // looked like it "fixed" the avatar.
  test('verify-otp response resolves avatar_url (not the raw key)', async () => {
    const email = 'avatar-resolve@test.com';

    // Create a user directly with an S3-style key in avatar_url so
    // the existing-user branch of resolveUser returns it on login.
    const { rows: uRows } = await query(
      `INSERT INTO users (email, email_hash, username, display_name, avatar_url)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [
        email,
        crypto.createHash('sha256').update(email).digest('hex'),
        `u${Math.random().toString(36).slice(2, 18)}`,
        'Avatar Resolve',
        'abc123-raw-key',
      ],
    );
    expect(uRows[0].avatar_url).toBe('abc123-raw-key');

    // Request OTP then submit — both hit the verify-otp endpoint.
    await request(app).post('/v1/auth/request-otp').send({ email });
    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({ email, code: '123456' });

    expect(res.status).toBe(200);
    const returnedUrl = res.body.user.avatar_url as string;
    expect(returnedUrl).not.toBe('abc123-raw-key');
    expect(returnedUrl).toContain('abc123-raw-key');
  });

  test('Registration without invite code creates user with no connections', async () => {
    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'noinvite@test.com' });

    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email: 'noinvite@test.com',
        code: '123456',
        display_name: 'No Invite User',
      });

    expect(res.status).toBe(200);
    expect(res.body.access_token).toBeDefined();
    expect(res.body.user.display_name).toBe('No Invite User');

    // User should have no follows
    const { rows: follows } = await query(
      'SELECT * FROM follows WHERE follower_id = $1 OR followee_id = $1',
      [res.body.user.id],
    );
    expect(follows.length).toBe(0);

    // User should still get invite codes
    const { rows: invites } = await query(
      'SELECT * FROM invites WHERE created_by_user_id = $1',
      [res.body.user.id],
    );
    expect(invites.length).toBeGreaterThan(0);
  });

  test('Existing user login flow', async () => {
    const { user } = await createTestUser({ email: 'existing-login@test.com' });

    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'existing-login@test.com' });

    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({ email: 'existing-login@test.com', code: '123456' });

    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe(user.id);
    expect(res.body.access_token).toBeDefined();
  });

  test('Token refresh flow', async () => {
    const { user } = await createTestUser({ email: 'refresh-test@test.com' });

    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'refresh-test@test.com' });

    const loginRes = await request(app)
      .post('/v1/auth/verify-otp')
      .send({ email: 'refresh-test@test.com', code: '123456' });

    const refreshRes = await request(app)
      .post('/v1/auth/refresh')
      .send({ refresh_token: loginRes.body.refresh_token });

    expect(refreshRes.status).toBe(200);
    expect(refreshRes.body.access_token).toBeDefined();
  });

  test('Logout invalidates refresh token', async () => {
    const { user } = await createTestUser({ email: 'logout-test@test.com' });

    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'logout-test@test.com' });

    const loginRes = await request(app)
      .post('/v1/auth/verify-otp')
      .send({ email: 'logout-test@test.com', code: '123456' });

    // Logout
    const logoutRes = await request(app)
      .delete('/v1/auth/session')
      .set('Authorization', `Bearer ${loginRes.body.access_token}`)
      .send({ refresh_token: loginRes.body.refresh_token });
    expect(logoutRes.status).toBe(200);

    // Refresh should now fail
    const refreshRes = await request(app)
      .post('/v1/auth/refresh')
      .send({ refresh_token: loginRes.body.refresh_token });
    expect(refreshRes.status).toBe(401);
  });
});

// ==================== USERS ====================
describe('Users', () => {
  test('GET /v1/users/me returns current user', async () => {
    const { user, token } = await createTestUser();
    const res = await request(app)
      .get('/v1/users/me')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe(user.id);
  });

  test('GET /v1/users/me includes plan_limits', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .get('/v1/users/me')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.plan_limits).toBeDefined();
    expect(res.body.plan_limits.feed_history_days).toBe(30); // free plan = 30 days
    expect(res.body.plan_limits.max_photos_per_post).toBe(10);
    expect(res.body.plan_limits.max_groups).toBe(10);
    expect(res.body.plan_limits.max_video_story_seconds).toBe(30);
  });

  test('GET /v1/users/me plan_limits reflect expired plan', async () => {
    const { token } = await createTestUser({ subscription_status: 'expired' });
    const res = await request(app)
      .get('/v1/users/me')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.plan_limits.feed_history_days).toBe(30);
  });

  test('GET /v1/users/me rejects unauthenticated', async () => {
    const res = await request(app).get('/v1/users/me');
    expect(res.status).toBe(401);
  });

  test('POST /v1/users/me/upload-url returns presigned URL', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/users/me/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({ content_type: 'image/jpeg' });
    expect(res.status).toBe(200);
    expect(res.body.upload_url).toBeDefined();
    expect(res.body.key).toBeDefined();
    expect(res.body.key).toMatch(/^avatar-/);
  });

  test('POST /v1/users/me/upload-url rejects missing content_type', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/users/me/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({});
    expect(res.status).toBe(400);
  });

  test('PATCH /v1/users/me updates profile', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .patch('/v1/users/me')
      .set('Authorization', `Bearer ${token}`)
      .send({ display_name: 'Updated Name', bio: 'My bio' });
    expect(res.status).toBe(200);
    expect(res.body.user.display_name).toBe('Updated Name');
    expect(res.body.user.bio).toBe('My bio');
  });

  test('GET /v1/users/:id returns profile', async () => {
    const { user: target } = await createTestUser();
    const { user: viewer, token } = await createTestUser();

    const res = await request(app)
      .get(`/v1/users/${target.id}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.user.display_name).toBe(target.display_name);
    // Not mutual follow, so no bio
    expect(res.body.user.bio).toBeUndefined();
  });

  test('GET /v1/users/:id includes bio for mutual follows', async () => {
    const { user: target } = await createTestUser();
    const { user: viewer, token } = await createTestUser();

    // Set bio on target
    await query("UPDATE users SET bio = 'Hello world' WHERE id = $1", [target.id]);

    // Create mutual follow
    await createMutualFollow(viewer.id, target.id);

    const res = await request(app)
      .get(`/v1/users/${target.id}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.user.bio).toBe('Hello world');
  });

  test('GET /v1/users/:id includes is_followed_by status', async () => {
    const { user: target } = await createTestUser();
    const { user: viewer, token } = await createTestUser();

    // No relationship
    const res1 = await request(app)
      .get(`/v1/users/${target.id}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res1.body.user.is_following).toBe(false);
    expect(res1.body.user.is_followed_by).toBe(false);

    // Target follows viewer (inbound request)
    await query('INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)', [target.id, viewer.id]);

    const res2 = await request(app)
      .get(`/v1/users/${target.id}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res2.body.user.is_following).toBe(false);
    expect(res2.body.user.is_followed_by).toBe(true);
  });

  test('GET /v1/users/search only returns mutual follows', async () => {
    const { user: viewer, token } = await createTestUser({
      display_name: 'Search Viewer',
    });
    const { user: mutual } = await createTestUser({
      display_name: 'Search Match Mutual',
    });
    const { user: oneWay } = await createTestUser({
      display_name: 'Search Match One Way',
    });
    const { user: stranger } = await createTestUser({
      display_name: 'Search Match Stranger',
    });

    await createMutualFollow(viewer.id, mutual.id);
    await query(
      'INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)',
      [viewer.id, oneWay.id],
    );

    const res = await request(app)
      .get('/v1/users/search?q=Search%20Match')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    const ids = res.body.users.map((u: any) => u.id);
    expect(ids).toContain(mutual.id);
    expect(ids).not.toContain(oneWay.id);
    expect(ids).not.toContain(stranger.id);
  });

  test('DELETE /v1/users/me soft-deletes account', async () => {
    const { user, token } = await createTestUser();
    const res = await request(app)
      .delete('/v1/users/me')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);

    const { rows } = await query('SELECT deleted_at FROM users WHERE id = $1', [user.id]);
    expect(rows[0].deleted_at).not.toBeNull();
  });
});

// ==================== FOLLOWS ====================
describe('Follows', () => {
  // Helper: did the most recent notification for `userId` get its
  // push_sent_at stamped? Proxy for "did the push actually fire."
  // The push itself is a no-op in test (no Firebase creds) so we
  // can't observe FCM directly — but the stamp is set on success
  // inside the route handler.
  async function latestPushStamped(userId: string): Promise<boolean> {
    const { rows } = await query(
      `SELECT push_sent_at FROM notifications
       WHERE user_id = $1
       ORDER BY created_at DESC LIMIT 1`,
      [userId],
    );
    return rows.length > 0 && rows[0].push_sent_at !== null;
  }

  // Helper: stash a device token for `userId` so the push path
  // executes through to stampPushSent. Without a device token the
  // route short-circuits before stamping (no point stamping if
  // there's no device to deliver to).
  async function seedDeviceToken(userId: string): Promise<void> {
    await query(
      `INSERT INTO device_tokens (user_id, token, platform)
       VALUES ($1, $2, 'ios')`,
      [userId, `tok-${userId.slice(0, 8)}-${Date.now()}`],
    );
  }

  test('POST /v1/follows fires push on first inbound_follow', async () => {
    const { token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();
    await seedDeviceToken(b.id);

    await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: b.id });

    expect(await latestPushStamped(b.id)).toBe(true);
  });

  test('POST /v1/follows is throttled if a recent push already fired', async () => {
    const { token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();
    const { user: c } = await createTestUser();
    await seedDeviceToken(b.id);

    // Seed a recent push to b — simulates b having gotten any push
    // (e.g. a comment) inside the throttle window.
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type, push_sent_at)
       VALUES ($1, 'comment', $2, 'post', NOW())`,
      [b.id, c.id],
    );

    // a follows b — notification row should still insert, but push
    // should NOT fire (no stamp on the new notification).
    await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: b.id });

    // Most recent un-stamped row exists (the follow we just made),
    // because the throttle filtered out the push.
    const { rows } = await query(
      `SELECT type, push_sent_at FROM notifications
       WHERE user_id = $1
       ORDER BY created_at DESC LIMIT 1`,
      [b.id],
    );
    expect(rows[0].type).toBe('inbound_follow');
    expect(rows[0].push_sent_at).toBeNull();
  });

  test('POST /v1/follows creates a follow', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();

    const res = await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: b.id });
    expect(res.status).toBe(201);
    expect(res.body.is_mutual).toBe(false);
  });

  test('Following back creates mutual follow', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b, token: tokenB } = await createTestUser();

    await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: b.id });

    const res = await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ user_id: a.id });
    expect(res.status).toBe(201);
    expect(res.body.is_mutual).toBe(true);
  });

  test('Cannot follow yourself', async () => {
    const { user, token } = await createTestUser();
    const res = await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${token}`)
      .send({ user_id: user.id });
    expect(res.status).toBe(400);
  });

  test('Double-follow is idempotent (returns 200)', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();

    await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: b.id });

    const res = await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: b.id });
    expect(res.status).toBe(200);
    expect(res.body.follow).toBeDefined();
  });

  test('DELETE /v1/follows/:user_id unfollows', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();

    await createMutualFollow(a.id, b.id);

    const res = await request(app)
      .delete(`/v1/follows/${b.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
  });

  test('GET /v1/follows/mutual lists mutual follows', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();
    const { user: c } = await createTestUser();

    await createMutualFollow(a.id, b.id);
    // c only follows a (not mutual)
    await query('INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)', [c.id, a.id]);

    const res = await request(app)
      .get('/v1/follows/mutual')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.users.length).toBe(1);
    expect(res.body.users[0].id).toBe(b.id);
  });

  test('GET /v1/follows/inbound lists pending follow-backs', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();

    // b follows a, a hasn't followed back
    await query('INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)', [b.id, a.id]);

    const res = await request(app)
      .get('/v1/follows/inbound')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.users.length).toBe(1);
    expect(res.body.users[0].id).toBe(b.id);
  });

  test('GET /v1/follows/outbound lists pending outbound requests', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();

    // a follows b, b hasn't followed back
    await query('INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)', [a.id, b.id]);

    const res = await request(app)
      .get('/v1/follows/outbound')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.users.length).toBe(1);
    expect(res.body.users[0].id).toBe(b.id);
  });

  test('GET /v1/follows/outbound excludes mutual follows', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();

    // Create mutual follow
    await createMutualFollow(a.id, b.id);

    const res = await request(app)
      .get('/v1/follows/outbound')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    // b should NOT appear since it's mutual
    const ids = res.body.users.map((u: any) => u.id);
    expect(ids).not.toContain(b.id);
  });

  test('GET /v1/follows/mutual/:userId returns target user connections with relationship annotations', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();
    const { user: c } = await createTestUser();

    // a and b are mutual, b and c are mutual
    await createMutualFollow(a.id, b.id);
    await createMutualFollow(b.id, c.id);

    // a views b's connections — should see c with relationship annotations
    const res = await request(app)
      .get(`/v1/follows/mutual/${b.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.users.length).toBeGreaterThanOrEqual(1);

    // c should be in b's connections (a is excluded since a is the requester)
    const cEntry = res.body.users.find((u: any) => u.id === c.id);
    expect(cEntry).toBeDefined();
    expect(cEntry.i_follow_them).toBeDefined();
    expect(cEntry.they_follow_me).toBeDefined();
    expect(cEntry.is_mutual).toBeDefined();
  });

  test('GET /v1/follows/mutual/:userId includes the requesting user when they are a connection of the target', async () => {
    // Build 25: the API used to filter the viewer out of the result set, which
    // produced a confusing empty list when the viewer was the target's only
    // mutual. The frontend now renders the viewer as a non-tappable "(You)"
    // row instead.
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();

    await createMutualFollow(a.id, b.id);

    // a views b's connections — a is one of b's mutuals, so a should appear
    const res = await request(app)
      .get(`/v1/follows/mutual/${b.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    const ids = res.body.users.map((u: any) => u.id);
    expect(ids).toContain(a.id);
  });

  test('GET /v1/follows/mutual/:userId denied for non-mutual user', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();

    // a and b are NOT connected
    const res = await request(app)
      .get(`/v1/follows/mutual/${b.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(403);
  });

  test('GET /v1/follows/mutual/:userId allowed for own connections', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b } = await createTestUser();

    await createMutualFollow(a.id, b.id);

    // a views own connections
    const res = await request(app)
      .get(`/v1/follows/mutual/${a.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.users.length).toBeGreaterThanOrEqual(1);
  });

  test('GET /v1/follows/mutual excludes system user', async () => {
    const { user: a, token: tokenA } = await createTestUser();

    // Create the sentinel system user and make a mutual follow with
    // it. The mutual-follow query MUST exclude this user by email so
    // it never appears in friend lists.
    const { rows: systemUsers } = await query(
      `INSERT INTO users (email, username, display_name)
       VALUES ($1, 'system_test', 'System')
       ON CONFLICT (email) DO UPDATE SET username = 'system_test'
       RETURNING id`,
      [SYSTEM_USER_EMAIL],
    );
    await createMutualFollow(a.id, systemUsers[0].id);

    const res = await request(app)
      .get('/v1/follows/mutual')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    const ids = res.body.users.map((u: any) => u.id);
    expect(ids).not.toContain(systemUsers[0].id);
  });
});

// ==================== INVITES ====================
describe('Invites', () => {
  test('GET /v1/invites lists invites', async () => {
    const { user, token } = await createTestUser();
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
      [user.id, `test${Math.random().toString(36).slice(2, 14)}`],
    );

    const res = await request(app)
      .get('/v1/invites')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.invites.length).toBeGreaterThanOrEqual(1);
  });

  test('POST /v1/invites creates invite', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/invites')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(201);
    expect(res.body.invite.code).toMatch(/^[a-f0-9]{12}$/);
    expect(res.body.invite.status).toBe('pending');
  });

  test('POST /v1/invites allows invites under the limit', async () => {
    const { user, token } = await createTestUser();
    // Create 5 invites — should not hit the 10 limit
    for (let i = 0; i < 5; i++) {
      await query(
        `INSERT INTO invites (created_by_user_id, code, status, expires_at)
         VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
        [user.id, `testlimit${i}${Math.random().toString(36).slice(2, 8)}`],
      );
    }

    const res = await request(app)
      .post('/v1/invites')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(201);
  });

  test('DELETE /v1/invites/:id revokes invite', async () => {
    const { user, token } = await createTestUser();
    const { rows } = await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days') RETURNING *`,
      [user.id, `testrevoke${Math.random().toString(36).slice(2, 8)}`],
    );

    const res = await request(app)
      .delete(`/v1/invites/${rows[0].id}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);

    const { rows: updated } = await query('SELECT status FROM invites WHERE id = $1', [rows[0].id]);
    expect(updated[0].status).toBe('revoked');
  });

  test('GET /v1/invites/validate/:code validates invite', async () => {
    const { user } = await createTestUser();
    const code = `testvalid${Math.random().toString(36).slice(2, 8)}`;
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
      [user.id, code],
    );

    const res = await request(app).get(`/v1/invites/validate/${code}`);
    expect(res.status).toBe(200);
    expect(res.body.valid).toBe(true);
    expect(res.body.inviter.display_name).toBe(user.display_name);
  });

  test('GET /v1/invites/validate/:code returns false for invalid code', async () => {
    const res = await request(app).get('/v1/invites/validate/nonexistent00');
    expect(res.status).toBe(200);
    expect(res.body.valid).toBe(false);
  });

  test('POST /v1/invites enforces limit of 25', async () => {
    const { user, token } = await createTestUser();
    // Insert 25 invites directly
    for (let i = 0; i < 25; i++) {
      await query(
        `INSERT INTO invites (created_by_user_id, code, status, expires_at)
         VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
        [user.id, `limit25test${i}${Math.random().toString(36).slice(2, 8)}`],
      );
    }

    // 26th should fail
    const res = await request(app)
      .post('/v1/invites')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(400);
    expect(res.body.error).toContain('25');
  });

  test('POST /v1/invites/redeem redeems invite code for existing user', async () => {
    const { user: inviter, token: inviterToken } = await createTestUser();
    const { user: redeemer, token: redeemerToken } = await createTestUser();

    // Create an invite for inviter
    const code = `redeem${Math.random().toString(36).slice(2, 10)}`;
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
      [inviter.id, code],
    );

    const res = await request(app)
      .post('/v1/invites/redeem')
      .set('Authorization', `Bearer ${redeemerToken}`)
      .send({ code });

    expect(res.status).toBe(200);
    expect(res.body.is_mutual).toBe(true);

    // Verify mutual follow was created
    const { rows: follows } = await query(
      'SELECT * FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [redeemer.id, inviter.id],
    );
    expect(follows.length).toBe(1);
    const { rows: reverseFollows } = await query(
      'SELECT * FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [inviter.id, redeemer.id],
    );
    expect(reverseFollows.length).toBe(1);

    // Verify invite is marked as used
    const { rows: usedInvites } = await query(
      'SELECT * FROM invites WHERE code = $1',
      [code],
    );
    expect(usedInvites[0].status).toBe('used');
    expect(usedInvites[0].used_by_user_id).toBe(redeemer.id);
  });

  test('POST /v1/invites/redeem auto-connects (always mutual)', async () => {
    const { user: inviter } = await createTestUser();
    const { user: redeemer, token: redeemerToken } = await createTestUser();

    const code = `mutual${Math.random().toString(36).slice(2, 10)}`;
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
      [inviter.id, code],
    );

    const res = await request(app)
      .post('/v1/invites/redeem')
      .set('Authorization', `Bearer ${redeemerToken}`)
      .send({ code });

    expect(res.status).toBe(200);
    expect(res.body.is_mutual).toBe(true);
    expect(res.body.message).toBe('Connected successfully');
  });

  test('POST /v1/invites/redeem rejects own invite', async () => {
    const { user, token } = await createTestUser();

    const code = `owncode${Math.random().toString(36).slice(2, 10)}`;
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
      [user.id, code],
    );

    const res = await request(app)
      .post('/v1/invites/redeem')
      .set('Authorization', `Bearer ${token}`)
      .send({ code });

    expect(res.status).toBe(400);
  });

  test('POST /v1/invites/redeem rejects already connected users', async () => {
    const { user: inviter } = await createTestUser();
    const { user: redeemer, token: redeemerToken } = await createTestUser();

    // Already mutually connected
    await createMutualFollow(redeemer.id, inviter.id);

    const code = `alrconn${Math.random().toString(36).slice(2, 10)}`;
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
      [inviter.id, code],
    );

    const res = await request(app)
      .post('/v1/invites/redeem')
      .set('Authorization', `Bearer ${redeemerToken}`)
      .send({ code });

    expect(res.status).toBe(409);
  });

  test('PATCH /v1/invites/:id marks invite as sent', async () => {
    const { user, token } = await createTestUser();
    const { rows } = await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days') RETURNING *`,
      [user.id, `sent${Math.random().toString(36).slice(2, 8)}`],
    );

    const res = await request(app)
      .patch(`/v1/invites/${rows[0].id}`)
      .set('Authorization', `Bearer ${token}`)
      .send({ status: 'sent' });
    expect(res.status).toBe(200);
    expect(res.body.invite.status).toBe('sent');
  });

  test('PATCH /v1/invites/:id rejects non-sent status', async () => {
    const { user, token } = await createTestUser();
    const { rows } = await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days') RETURNING *`,
      [user.id, `nosent${Math.random().toString(36).slice(2, 8)}`],
    );

    const res = await request(app)
      .patch(`/v1/invites/${rows[0].id}`)
      .set('Authorization', `Bearer ${token}`)
      .send({ status: 'used' });
    expect(res.status).toBe(400);
  });

  test('PATCH /v1/invites/:id rejects marking already-used invite as sent', async () => {
    const { user, token } = await createTestUser();
    const { rows } = await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'used', NOW() + INTERVAL '30 days') RETURNING *`,
      [user.id, `used${Math.random().toString(36).slice(2, 8)}`],
    );

    const res = await request(app)
      .patch(`/v1/invites/${rows[0].id}`)
      .set('Authorization', `Bearer ${token}`)
      .send({ status: 'sent' });
    expect(res.status).toBe(404);
  });

  test('Sent invite can still be validated', async () => {
    const { user } = await createTestUser();
    const code = `sentvalid${Math.random().toString(36).slice(2, 8)}`;
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'sent', NOW() + INTERVAL '30 days')`,
      [user.id, code],
    );

    const res = await request(app).get(`/v1/invites/validate/${code}`);
    expect(res.status).toBe(200);
    expect(res.body.valid).toBe(true);
  });

  test('Sent invite can be redeemed', async () => {
    const { user: inviter } = await createTestUser();
    const { token: redeemerToken } = await createTestUser();

    const code = `sentredeem${Math.random().toString(36).slice(2, 8)}`;
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'sent', NOW() + INTERVAL '30 days')`,
      [inviter.id, code],
    );

    const res = await request(app)
      .post('/v1/invites/redeem')
      .set('Authorization', `Bearer ${redeemerToken}`)
      .send({ code });
    expect(res.status).toBe(200);
    expect(res.body.is_mutual).toBe(true);
  });

  test('POST /v1/invites/redeem rejects invalid code', async () => {
    const { token } = await createTestUser();

    const res = await request(app)
      .post('/v1/invites/redeem')
      .set('Authorization', `Bearer ${token}`)
      .send({ code: 'nonexistent99' });

    expect(res.status).toBe(404);
  });
});

// ==================== PERSONAL INVITE LINK (SLUG) ====================
//
// Slug-based personal invite URLs (`http://localhost:3000/<slug>`)
// replace invite codes as the primary share affordance. See
// src/routes/invite-link.ts and migration 026 for the full design.
describe('Personal invite link (slug)', () => {
  // ---- GET /v1/invite-link ----
  test('GET /v1/invite-link returns the caller\'s slug + URL', async () => {
    const { user, token } = await createTestUser();
    // Migration 026 backfilled a slug for createTestUser's row;
    // sanity-check by querying directly first.
    const { rows } = await query(
      'SELECT invite_slug FROM users WHERE id = $1',
      [user.id],
    );
    // createTestUser inserts without specifying invite_slug, so it's
    // NULL at insertion time. The GET handler auto-generates on
    // first call (defensive branch).
    expect(rows[0].invite_slug).toBeNull();

    const res = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.slug).toMatch(/^[a-z0-9]{12}$/);
    expect(res.body.url).toBe(`http://localhost:3000/${res.body.slug}`);

    // Subsequent calls return the same slug (no churn).
    const second = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${token}`);
    expect(second.body.slug).toBe(res.body.slug);
  });

  test('GET /v1/invite-link requires auth', async () => {
    const res = await request(app).get('/v1/invite-link');
    expect(res.status).toBe(401);
  });

  // ---- POST /v1/invite-link/regenerate ----
  test('POST /v1/invite-link/regenerate rotates the slug and invalidates the old one', async () => {
    const { token } = await createTestUser();
    const first = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${token}`);
    const oldSlug = first.body.slug;

    const rotate = await request(app)
      .post('/v1/invite-link/regenerate')
      .set('Authorization', `Bearer ${token}`);
    expect(rotate.status).toBe(200);
    expect(rotate.body.slug).toMatch(/^[a-z0-9]{12}$/);
    expect(rotate.body.slug).not.toBe(oldSlug);

    // The old slug should no longer resolve.
    const oldLookup = await request(app)
      .get(`/v1/users/by-slug/${oldSlug}`)
      .set('Authorization', `Bearer ${token}`);
    expect(oldLookup.status).toBe(404);

    // The new slug resolves.
    const newLookup = await request(app)
      .get(`/v1/users/by-slug/${rotate.body.slug}`)
      .set('Authorization', `Bearer ${token}`);
    expect(newLookup.status).toBe(200);
  });

  test('POST /v1/invite-link/regenerate stamps rotated_at', async () => {
    const { user, token } = await createTestUser();
    await request(app)
      .post('/v1/invite-link/regenerate')
      .set('Authorization', `Bearer ${token}`);
    const { rows } = await query(
      'SELECT invite_slug_rotated_at FROM users WHERE id = $1',
      [user.id],
    );
    expect(rows[0].invite_slug_rotated_at).toBeTruthy();
  });

  // ---- POST /v1/invite-link/request ----
  test('POST /v1/invite-link/request creates a one-way follow + notification', async () => {
    const { user: alice, token: aliceToken } = await createTestUser();
    const { user: bob, token: bobToken } = await createTestUser();

    // Alice gets her slug
    const aliceLink = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${aliceToken}`);
    const aliceSlug = aliceLink.body.slug;

    // Bob taps Alice's link, sends request
    const res = await request(app)
      .post('/v1/invite-link/request')
      .set('Authorization', `Bearer ${bobToken}`)
      .send({ slug: aliceSlug });
    expect(res.status).toBe(201);
    expect(res.body.status).toBe('requested');

    // One-way follow exists: bob → alice
    const { rows: follows } = await query(
      'SELECT * FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [bob.id, alice.id],
    );
    expect(follows.length).toBe(1);

    // Reverse direction does NOT exist (recipient must approve)
    const { rows: reverse } = await query(
      'SELECT * FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [alice.id, bob.id],
    );
    expect(reverse.length).toBe(0);

    // Notification was inserted for Alice
    const { rows: notifs } = await query(
      `SELECT * FROM notifications
       WHERE user_id = $1 AND actor_id = $2 AND type = 'inbound_follow'`,
      [alice.id, bob.id],
    );
    expect(notifs.length).toBe(1);
  });

  test('POST /v1/invite-link/request accepts a full URL, not just a bare slug', async () => {
    const { token: aliceToken } = await createTestUser();
    const { token: bobToken } = await createTestUser();

    const aliceLink = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${aliceToken}`);

    const res = await request(app)
      .post('/v1/invite-link/request')
      .set('Authorization', `Bearer ${bobToken}`)
      .send({ slug: aliceLink.body.url });
    expect(res.status).toBe(201);
    expect(res.body.status).toBe('requested');
  });

  test('POST /v1/invite-link/request is a silent no-op for self-slug', async () => {
    const { token } = await createTestUser();
    const link = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${token}`);

    const res = await request(app)
      .post('/v1/invite-link/request')
      .set('Authorization', `Bearer ${token}`)
      .send({ slug: link.body.slug });
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('self');
  });

  test('POST /v1/invite-link/request returns already_following on duplicate', async () => {
    const { token: aliceToken } = await createTestUser();
    const { token: bobToken } = await createTestUser();
    const aliceLink = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${aliceToken}`);

    await request(app)
      .post('/v1/invite-link/request')
      .set('Authorization', `Bearer ${bobToken}`)
      .send({ slug: aliceLink.body.slug });

    const second = await request(app)
      .post('/v1/invite-link/request')
      .set('Authorization', `Bearer ${bobToken}`)
      .send({ slug: aliceLink.body.slug });
    expect(second.status).toBe(200);
    expect(second.body.status).toBe('already_following');
  });

  test('POST /v1/invite-link/request returns already_mutual when reverse follow exists', async () => {
    const { user: alice, token: aliceToken } = await createTestUser();
    const { user: bob, token: bobToken } = await createTestUser();
    // Alice already follows Bob, but Bob hasn't followed back
    await query(
      'INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)',
      [alice.id, bob.id],
    );

    const aliceLink = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${aliceToken}`);

    // Bob taps Alice's link — should land in already_mutual on the
    // very first request (his new follow + Alice's existing reverse
    // close the loop).
    const res = await request(app)
      .post('/v1/invite-link/request')
      .set('Authorization', `Bearer ${bobToken}`)
      .send({ slug: aliceLink.body.slug });
    expect(res.status).toBe(201);
    expect(res.body.status).toBe('already_mutual');
  });

  test('POST /v1/invite-link/request rejects malformed slug', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/invite-link/request')
      .set('Authorization', `Bearer ${token}`)
      .send({ slug: 'not-a-slug' });
    expect(res.status).toBe(400);
  });

  test('POST /v1/invite-link/request 404s for unknown slug', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/invite-link/request')
      .set('Authorization', `Bearer ${token}`)
      .send({ slug: 'aaaaaaaaaaaa' });
    expect(res.status).toBe(404);
  });

  test('POST /v1/invite-link/request 404s for a deleted user\'s slug', async () => {
    const { user: alice, token: aliceToken } = await createTestUser();
    const { token: bobToken } = await createTestUser();
    const aliceLink = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${aliceToken}`);
    await query('UPDATE users SET deleted_at = NOW() WHERE id = $1', [alice.id]);

    const res = await request(app)
      .post('/v1/invite-link/request')
      .set('Authorization', `Bearer ${bobToken}`)
      .send({ slug: aliceLink.body.slug });
    expect(res.status).toBe(404);
  });

  // ---- GET /v1/users/by-slug/:slug ----
  test('GET /v1/users/by-slug/:slug returns minimal payload', async () => {
    const { user: alice, token: aliceToken } = await createTestUser({
      display_name: 'Alice Smith',
    });
    const { token: bobToken } = await createTestUser();
    const link = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${aliceToken}`);

    const res = await request(app)
      .get(`/v1/users/by-slug/${link.body.slug}`)
      .set('Authorization', `Bearer ${bobToken}`);
    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe(alice.id);
    expect(res.body.user.display_name).toBe('Alice Smith');
    // Minimal payload — no bio, no posts, no follow-status, no count
    expect(res.body.user.bio).toBeUndefined();
    expect(res.body.user.is_following).toBeUndefined();
    expect(res.body.user.mutual_count).toBeUndefined();
  });

  test('GET /v1/users/by-slug is case-insensitive', async () => {
    const { token: aliceToken } = await createTestUser();
    const { token: bobToken } = await createTestUser();
    const link = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${aliceToken}`);

    const upper = link.body.slug.toUpperCase();
    const res = await request(app)
      .get(`/v1/users/by-slug/${upper}`)
      .set('Authorization', `Bearer ${bobToken}`);
    expect(res.status).toBe(200);
  });

  test('GET /v1/users/by-slug rejects malformed slug with 400', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .get('/v1/users/by-slug/not-a-slug')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(400);
  });

  test('GET /v1/users/by-slug 404s for unknown slug', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .get('/v1/users/by-slug/aaaaaaaaaaaa')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(404);
  });

  test('GET /v1/users/by-slug requires auth', async () => {
    const res = await request(app).get('/v1/users/by-slug/aaaaaaaaaaaa');
    expect(res.status).toBe(401);
  });

  // ---- DELETE /v1/follows/inbound/:user_id (decline) ----
  test('DELETE /v1/follows/inbound/:user_id removes the inbound follow', async () => {
    const { user: alice, token: aliceToken } = await createTestUser();
    const { user: bob } = await createTestUser();
    // Bob follows Alice — pending, awaiting Alice's accept
    await query(
      'INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)',
      [bob.id, alice.id],
    );

    const res = await request(app)
      .delete(`/v1/follows/inbound/${bob.id}`)
      .set('Authorization', `Bearer ${aliceToken}`);
    expect(res.status).toBe(204);

    const { rows } = await query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [bob.id, alice.id],
    );
    expect(rows.length).toBe(0);
  });

  test('DELETE /v1/follows/inbound also clears the inbound_follow notification', async () => {
    const { user: alice, token: aliceToken } = await createTestUser();
    const { user: bob } = await createTestUser();
    await query(
      'INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2)',
      [bob.id, alice.id],
    );
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_type)
       VALUES ($1, 'inbound_follow', $2, 'follow')`,
      [alice.id, bob.id],
    );

    await request(app)
      .delete(`/v1/follows/inbound/${bob.id}`)
      .set('Authorization', `Bearer ${aliceToken}`);

    const { rows } = await query(
      `SELECT * FROM notifications
       WHERE user_id = $1 AND actor_id = $2 AND type = 'inbound_follow'`,
      [alice.id, bob.id],
    );
    expect(rows.length).toBe(0);
  });

  test('DELETE /v1/follows/inbound is idempotent (returns 204 even if no row existed)', async () => {
    const { token: aliceToken } = await createTestUser();
    const { user: bob } = await createTestUser();
    const res = await request(app)
      .delete(`/v1/follows/inbound/${bob.id}`)
      .set('Authorization', `Bearer ${aliceToken}`);
    expect(res.status).toBe(204);
  });

  // ---- Signup via slug ----
  test('Signup with a slug in the invite_code field creates a ONE-WAY follow (not mutual)', async () => {
    // Inviter exists with a known slug.
    const { user: inviter, token: inviterToken } = await createTestUser({
      email: 'slug-inviter@test.com',
    });
    const link = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${inviterToken}`);
    const slug = link.body.slug;

    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'slug-newuser@test.com' });

    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email: 'slug-newuser@test.com',
        code: '123456',
        invite_code: slug,
        display_name: 'Slug Newcomer',
      });
    expect(res.status).toBe(200);

    // New user follows inviter
    const { rows: forward } = await query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [res.body.user.id, inviter.id],
    );
    expect(forward.length).toBe(1);

    // Inviter does NOT follow new user (one-way until inviter approves)
    const { rows: reverse } = await query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [inviter.id, res.body.user.id],
    );
    expect(reverse.length).toBe(0);

    // Inbound-follow notification fired to the inviter
    const { rows: notifs } = await query(
      `SELECT * FROM notifications
       WHERE user_id = $1 AND actor_id = $2 AND type = 'inbound_follow'`,
      [inviter.id, res.body.user.id],
    );
    expect(notifs.length).toBe(1);
  });

  test('Signup with a full invite URL in the invite_code field works the same as a bare slug', async () => {
    const { user: inviter, token: inviterToken } = await createTestUser({
      email: 'url-inviter@test.com',
    });
    const link = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${inviterToken}`);

    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'url-newuser@test.com' });

    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email: 'url-newuser@test.com',
        code: '123456',
        invite_code: link.body.url, // full URL, not bare slug
        display_name: 'URL Newcomer',
      });
    expect(res.status).toBe(200);

    const { rows: forward } = await query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [res.body.user.id, inviter.id],
    );
    expect(forward.length).toBe(1);
  });

  test('Signup via slug allocates the new user their own invite_slug', async () => {
    const { token: inviterToken } = await createTestUser({
      email: 'allocate-inviter@test.com',
    });
    const link = await request(app)
      .get('/v1/invite-link')
      .set('Authorization', `Bearer ${inviterToken}`);

    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'allocate-newuser@test.com' });

    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email: 'allocate-newuser@test.com',
        code: '123456',
        invite_code: link.body.slug,
        display_name: 'Allocate Newcomer',
      });
    expect(res.status).toBe(200);

    const { rows } = await query(
      'SELECT invite_slug FROM users WHERE id = $1',
      [res.body.user.id],
    );
    expect(rows[0].invite_slug).toMatch(/^[a-z0-9]{12}$/);
  });

  test('Signup with a legacy invite code still creates a MUTUAL follow', async () => {
    // Regression — make sure the URL/slug disambiguator didn't
    // accidentally steal legacy codes that happen to be 12 lowercase
    // hex (a subset of the slug alphabet).
    const { user: inviter } = await createTestUser({
      email: 'legacy-inviter@test.com',
    });
    const code = `legacy${Math.random().toString(36).slice(2, 8)}`;
    await query(
      `INSERT INTO invites (created_by_user_id, code, status, expires_at)
       VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')`,
      [inviter.id, code],
    );

    await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: 'legacy-newuser@test.com' });

    const res = await request(app)
      .post('/v1/auth/verify-otp')
      .send({
        email: 'legacy-newuser@test.com',
        code: '123456',
        invite_code: code,
        display_name: 'Legacy Newcomer',
      });
    expect(res.status).toBe(200);

    // Legacy path creates BOTH directions (mutual on signup)
    const { rows: forward } = await query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [res.body.user.id, inviter.id],
    );
    const { rows: reverse } = await query(
      'SELECT 1 FROM follows WHERE follower_id = $1 AND followee_id = $2',
      [inviter.id, res.body.user.id],
    );
    expect(forward.length).toBe(1);
    expect(reverse.length).toBe(1);
  });

  // ---- Migration 026 backfill ----
  test('Migration 026 created the LOWER(invite_slug) unique index', async () => {
    const { rows } = await query(
      `SELECT indexname FROM pg_indexes
       WHERE tablename = 'users' AND indexname = 'users_invite_slug_lower_idx'`,
    );
    expect(rows.length).toBe(1);
  });

  test('Migration 026 added the invite_slug_rotated_at column', async () => {
    const { rows } = await query(
      `SELECT column_name FROM information_schema.columns
       WHERE table_name = 'users' AND column_name = 'invite_slug_rotated_at'`,
    );
    expect(rows.length).toBe(1);
  });
});

// ==================== POSTS & FEED ====================
describe('Posts & Feed', () => {
  let userA: any, tokenA: string;
  let userB: any, tokenB: string;

  beforeEach(async () => {
    ({ user: userA, token: tokenA } = await createTestUser());
    ({ user: userB, token: tokenB } = await createTestUser());
    await createMutualFollow(userA.id, userB.id);
  });

  test('POST /v1/posts/upload-url returns presigned URLs', async () => {
    const res = await request(app)
      .post('/v1/posts/upload-url')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ content_type: 'image/jpeg', count: 3 });
    expect(res.status).toBe(200);
    expect(res.body.uploads.length).toBe(3);
    expect(res.body.uploads[0].upload_url).toBeDefined();
    expect(res.body.uploads[0].key).toBeDefined();
  });

  test('POST /v1/posts creates a post with media', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Hello world!',
        media: [
          { key: 'photo1.jpg', media_type: 'photo', width: 1080, height: 1920, position: 0 },
        ],
      });
    expect(res.status).toBe(201);
    expect(res.body.post.caption).toBe('Hello world!');
    expect(res.body.post.media.length).toBe(1);
  });

  test('POST /v1/posts creates a post with video media', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Check out this video',
        media: [
          { key: 'clip.mp4', media_type: 'video', width: 1080, height: 1920, position: 0 },
        ],
      });
    expect(res.status).toBe(201);
    expect(res.body.post.media.length).toBe(1);
    expect(res.body.post.media[0].media_type).toBe('video');
  });

  test('POST /v1/posts creates a post with mixed photo and video media', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Mixed media post',
        media: [
          { key: 'photo1.jpg', media_type: 'photo', width: 1080, height: 1080, position: 0 },
          { key: 'clip.mp4', media_type: 'video', width: 1080, height: 1920, position: 1 },
        ],
      });
    expect(res.status).toBe(201);
    expect(res.body.post.media.length).toBe(2);
    expect(res.body.post.media[0].media_type).toBe('photo');
    expect(res.body.post.media[1].media_type).toBe('video');
  });

  test('POST /v1/posts allows text-only post (no media)', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ caption: 'Text-only post' });
    expect(res.status).toBe(201);
    expect(res.body.post.caption).toBe('Text-only post');
  });

  test('POST /v1/posts rejects post without caption or media', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({});
    expect(res.status).toBe(400);
  });

  test('POST /v1/posts accepts a 2200-char caption at the limit', async () => {
    // Instagram-parity cap — voice-dictated long captions should land cleanly.
    const caption = 'x'.repeat(2200);
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ caption });
    expect(res.status).toBe(201);
    expect(res.body.post.caption.length).toBe(2200);
  });

  test('POST /v1/posts rejects a caption over 2200 chars', async () => {
    const caption = 'x'.repeat(2201);
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ caption });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/2200/);
  });

  test('POST /v1/posts rejects a non-string caption', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ caption: 123 });
    expect(res.status).toBe(400);
  });

  test('GET /v1/posts/:id returns post to mutual follow', async () => {
    // UserB creates post
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({
        caption: 'Test post',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    // UserA can view it (mutual follow)
    const res = await request(app)
      .get(`/v1/posts/${createRes.body.post.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.post.id).toBe(createRes.body.post.id);
  });

  test('GET /v1/posts/:id denies non-mutual follow', async () => {
    const { user: stranger, token: strangerToken } = await createTestUser();

    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Private post',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .get(`/v1/posts/${createRes.body.post.id}`)
      .set('Authorization', `Bearer ${strangerToken}`);
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Post not found');
  });

  test('DELETE /v1/posts/:id hard-deletes post', async () => {
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'To delete',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .delete(`/v1/posts/${createRes.body.post.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);

    // Post should not be findable
    const getRes = await request(app)
      .get(`/v1/posts/${createRes.body.post.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(getRes.status).toBe(404);
  });

  test('DELETE /v1/posts/:id cascades to media and comments', async () => {
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Post with comments',
        media: [
          { key: 'media1.jpg', media_type: 'photo', position: 0 },
          { key: 'media2.jpg', media_type: 'photo', position: 1 },
        ],
      });
    const postId = createRes.body.post.id;

    // Add a comment
    await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Nice photo!' });

    // Verify media and comments exist
    const { rows: mediaBefore } = await query('SELECT * FROM post_media WHERE post_id = $1', [postId]);
    expect(mediaBefore.length).toBe(2);
    const { rows: commentsBefore } = await query('SELECT * FROM comments WHERE post_id = $1', [postId]);
    expect(commentsBefore.length).toBe(1);

    // Delete the post
    const res = await request(app)
      .delete(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);

    // Media and comments should be gone
    const { rows: mediaAfter } = await query('SELECT * FROM post_media WHERE post_id = $1', [postId]);
    expect(mediaAfter.length).toBe(0);
    const { rows: commentsAfter } = await query('SELECT * FROM comments WHERE post_id = $1', [postId]);
    expect(commentsAfter.length).toBe(0);

    // Post row should be gone entirely (hard delete, not soft)
    const { rows: postRows } = await query('SELECT * FROM posts WHERE id = $1', [postId]);
    expect(postRows.length).toBe(0);
  });

  // Regression: a real user got a 404 after tapping a push notification
  // for a post the author had since deleted. The notification still
  // existed in the DB, so the deep link routed to a 404 with a generic
  // "resource not found" message. The DELETE handler now also clears
  // notifications referencing the post (and its comments, since those
  // are about to disappear too), so taps on stale pushes no longer
  // strand users on a 404.
  // Build 35: videos carry a thumbnail_url pointing at a first-frame
  // JPEG extracted client-side and uploaded as a sibling key. Server
  // must (a) persist the key when supplied as `thumbnail_key` on the
  // create payload, (b) return it as a resolved URL on read.
  test('POST /v1/posts persists thumbnail_key on video media and GET returns thumbnail_url', async () => {
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Video with thumb',
        media: [
          {
            key: 'video-abc.mp4',
            media_type: 'video',
            position: 0,
            thumbnail_key: 'video-abc-thumb.jpg',
          },
        ],
      });
    expect(createRes.status).toBe(201);
    const postId = createRes.body.post.id;

    // Directly inspect the row to confirm the column was written.
    const { rows: mediaRows } = await query(
      'SELECT media_url, thumbnail_url FROM post_media WHERE post_id = $1',
      [postId],
    );
    expect(mediaRows[0].media_url).toBe('video-abc.mp4');
    expect(mediaRows[0].thumbnail_url).toBe('video-abc-thumb.jpg');

    // On read, the endpoint resolves thumbnail_url through
    // resolveMediaUrl the same way it does media_url.
    const getRes = await request(app)
      .get(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(getRes.status).toBe(200);
    const media = getRes.body.post.media[0];
    expect(media.thumbnail_url).toBeTruthy();
    // In the test env resolveMediaUrl builds a dev-mode URL like
    // `http(s)://<host>/v1/posts/upload/<key>` — we just verify that
    // it's been resolved (contains the key somewhere) rather than
    // returned as the raw key.
    expect(media.thumbnail_url).toContain('video-abc-thumb.jpg');
    expect(media.thumbnail_url).not.toBe('video-abc-thumb.jpg');
  });

  // Photos don't get a thumbnail — the media_url itself is the still.
  test('POST /v1/posts keeps thumbnail_url null for photo media', async () => {
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Photo post',
        media: [{ key: 'photo.jpg', media_type: 'photo', position: 0 }],
      });
    expect(createRes.status).toBe(201);
    const postId = createRes.body.post.id;

    const { rows } = await query(
      'SELECT thumbnail_url FROM post_media WHERE post_id = $1',
      [postId],
    );
    expect(rows[0].thumbnail_url).toBeNull();

    const getRes = await request(app)
      .get(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(getRes.body.post.media[0].thumbnail_url).toBeNull();
  });

  test('DELETE /v1/posts/:id clears notifications referencing post + comments', async () => {
    // userA posts; userB likes + comments; both events generate
    // notifications to userA referencing the post / comment.
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Notification cleanup',
        media: [{ key: 'notif.jpg', media_type: 'photo', position: 0 }],
      });
    const postId = createRes.body.post.id;

    const commentRes = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Nice!' });
    const commentId = commentRes.body.comment.id;

    // Seed a 'post'-typed notification (the comment endpoint above
    // already created a 'comment'-typed one). We use 'new_post' since
    // it's an allowed value in the notifications type CHECK constraint.
    await query(
      `INSERT INTO notifications (user_id, type, actor_id, reference_id, reference_type)
       VALUES ($1, 'new_post', $2, $3, 'post')`,
      [userA.id, userB.id, postId],
    );

    // Sanity: notifications exist before delete.
    const { rows: beforePost } = await query(
      "SELECT id FROM notifications WHERE reference_type = 'post' AND reference_id = $1",
      [postId],
    );
    expect(beforePost.length).toBeGreaterThan(0);
    const { rows: beforeComment } = await query(
      "SELECT id FROM notifications WHERE reference_type = 'comment' AND reference_id = $1",
      [commentId],
    );
    expect(beforeComment.length).toBeGreaterThan(0);

    // Delete the post.
    const delRes = await request(app)
      .delete(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(delRes.status).toBe(200);

    // Both classes of stale notifications should be gone.
    const { rows: afterPost } = await query(
      "SELECT id FROM notifications WHERE reference_type = 'post' AND reference_id = $1",
      [postId],
    );
    expect(afterPost.length).toBe(0);
    const { rows: afterComment } = await query(
      "SELECT id FROM notifications WHERE reference_type = 'comment' AND reference_id = $1",
      [commentId],
    );
    expect(afterComment.length).toBe(0);
  });

  test('DELETE /v1/posts/:id returns 404 for other user post', async () => {
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({
        caption: 'Not yours',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .delete(`/v1/posts/${createRes.body.post.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(404);
  });

  test('PATCH /v1/posts/:id edits own post caption', async () => {
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Original caption',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });
    const postId = createRes.body.post.id;

    const editRes = await request(app)
      .patch(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ caption: 'Updated caption' });
    expect(editRes.status).toBe(200);
    expect(editRes.body.post.caption).toBe('Updated caption');
    expect(editRes.body.post.updated_at).toBeDefined();
  });

  test('PATCH /v1/posts/:id rejects editing other users post', async () => {
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({
        caption: 'Their post',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    const editRes = await request(app)
      .patch(`/v1/posts/${createRes.body.post.id}`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ caption: 'Hijacked!' });
    expect(editRes.status).toBe(404);
  });

  test('GET /v1/feed returns mutual follow posts chronologically', async () => {
    // UserB creates two posts
    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({
        caption: 'First',
        media: [{ key: 'img1.jpg', media_type: 'photo', position: 0 }],
      });

    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({
        caption: 'Second',
        media: [{ key: 'img2.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.posts.length).toBeGreaterThanOrEqual(2);
    // Should be reverse chronological
    const timestamps = res.body.posts.map((p: any) => new Date(p.created_at).getTime());
    for (let i = 1; i < timestamps.length; i++) {
      expect(timestamps[i - 1]).toBeGreaterThanOrEqual(timestamps[i]);
    }
  });

  test('Feed excludes non-mutual follow posts', async () => {
    const { user: stranger, token: strangerToken } = await createTestUser();
    // stranger makes a post - shouldn't appear in userA's feed
    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${strangerToken}`)
      .send({
        caption: 'Stranger post',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenA}`);
    const strangerPosts = res.body.posts.filter((p: any) => p.user_id === stranger.id);
    expect(strangerPosts.length).toBe(0);
  });

  test('Feed supports before cursor pagination', async () => {
    // Create a post with known time
    const createRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({
        caption: 'Cursor test',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .get('/v1/feed')
      .query({ before: createRes.body.post.created_at })
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    // All returned posts should be before the cursor
    for (const post of res.body.posts) {
      expect(new Date(post.created_at).getTime())
        .toBeLessThan(new Date(createRes.body.post.created_at).getTime());
    }
  });

  test('Feed rejects malformed before cursor with 400 instead of 500', async () => {
    // Build 25 regression: an early mobile cursor implementation sent the last
    // post's UUID instead of its `created_at`, which Postgres surfaced as a
    // `DateTimeParseError` 500. parseBeforeCursor now turns that into a clean
    // 400 so a buggy client can never crash the request.
    const res = await request(app)
      .get('/v1/feed')
      .query({ before: '78393e4a-e783-4163-b1c6-a9068d4c30e3' })
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(400);
  });

  test('Feed accepts ISO-8601 before cursor (the format the mobile client now sends)', async () => {
    const res = await request(app)
      .get('/v1/feed')
      .query({ before: new Date().toISOString() })
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body.posts)).toBe(true);
  });

  test('GET /v1/feed includes comment_count and recent_comments', async () => {
    // Create a post
    const postRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ caption: 'Comment preview test' });
    const postId = postRes.body.post.id;

    // Add 3 comments
    for (const body of ['First comment', 'Second comment', 'Third comment']) {
      await request(app)
        .post(`/v1/posts/${postId}/comments`)
        .set('Authorization', `Bearer ${tokenA}`)
        .send({ body });
    }

    // Fetch feed
    const feedRes = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(feedRes.status).toBe(200);
    const feedPost = feedRes.body.posts.find((p: any) => p.id === postId);
    expect(feedPost).toBeDefined();
    expect(feedPost.comment_count).toBe(3);
    expect(feedPost.recent_comments).toHaveLength(2);
    expect(feedPost.recent_comments[0].display_name).toBeDefined();
    expect(feedPost.recent_comments[0].body).toBeDefined();
  });

  test('GET /v1/feed returns comment_count 0 for posts without comments', async () => {
    const postRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ caption: 'No comments post' });
    const postId = postRes.body.post.id;

    const feedRes = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenA}`);
    const feedPost = feedRes.body.posts.find((p: any) => p.id === postId);
    expect(feedPost).toBeDefined();
    expect(feedPost.comment_count).toBe(0);
    expect(feedPost.recent_comments).toEqual([]);
  });

  test('GET /v1/posts/by-user/:id returns user posts', async () => {
    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({
        caption: 'By user test',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .get(`/v1/posts/by-user/${userB.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.posts.length).toBeGreaterThanOrEqual(1);
  });

  test('GET /v1/posts/by-user/:id hides non-mutual profiles', async () => {
    const { token: strangerToken } = await createTestUser();

    const res = await request(app)
      .get(`/v1/posts/by-user/${userB.id}`)
      .set('Authorization', `Bearer ${strangerToken}`);
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('User not found');
  });
});

// ==================== POST LIKES ====================
describe('Post Likes', () => {
  let userA: any, tokenA: string;
  let userB: any, tokenB: string;
  let postId: string;

  beforeEach(async () => {
    ({ user: userA, token: tokenA } = await createTestUser());
    ({ user: userB, token: tokenB } = await createTestUser());
    await createMutualFollow(userA.id, userB.id);

    const postRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Like test',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });
    postId = postRes.body.post.id;
  });

  test('POST /v1/posts/:id/like likes a post', async () => {
    const res = await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(res.status).toBe(200);
    expect(res.body.liked).toBe(true);
    expect(res.body.like_count).toBe(1);
  });

  test('POST /v1/posts/:id/like is idempotent', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);

    const res = await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(res.status).toBe(200);
    expect(res.body.liked).toBe(true);
    expect(res.body.like_count).toBe(1); // still 1, not 2
  });

  test('DELETE /v1/posts/:id/like unlikes a post', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);

    const res = await request(app)
      .delete(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(res.status).toBe(200);
    expect(res.body.liked).toBe(false);
    expect(res.body.like_count).toBe(0);
  });

  test('DELETE /v1/posts/:id/like on unliked post is harmless', async () => {
    const res = await request(app)
      .delete(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(res.status).toBe(200);
    expect(res.body.liked).toBe(false);
    expect(res.body.like_count).toBe(0);
  });

  test('Non-mutual users cannot like or inspect a private post', async () => {
    const { token: strangerToken } = await createTestUser();

    const likeRes = await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${strangerToken}`);
    expect(likeRes.status).toBe(404);
    expect(likeRes.body.error).toBe('Post not found');

    const unlikeRes = await request(app)
      .delete(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${strangerToken}`);
    expect(unlikeRes.status).toBe(404);
    expect(unlikeRes.body.error).toBe('Post not found');

    const likesRes = await request(app)
      .get(`/v1/posts/${postId}/likes`)
      .set('Authorization', `Bearer ${strangerToken}`);
    expect(likesRes.status).toBe(404);
    expect(likesRes.body.error).toBe('Post not found');
  });

  test('Multiple users can like the same post', async () => {
    const { token: tokenC } = await createTestUser();
    // Make C mutual with A so they can access the post
    await createMutualFollow(userA.id, (await query('SELECT id FROM users ORDER BY created_at DESC LIMIT 1')).rows[0].id);

    await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenA}`);

    await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);

    // Check count via GET
    const res = await request(app)
      .get(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.body.post.like_count).toBe(2);
  });

  test('GET /v1/posts/:id includes like_count and is_liked', async () => {
    // B likes the post
    await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);

    // B sees is_liked: true
    const resB = await request(app)
      .get(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(resB.body.post.like_count).toBe(1);
    expect(resB.body.post.is_liked).toBe(true);

    // A sees is_liked: false (they didn't like it)
    const resA = await request(app)
      .get(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(resA.body.post.like_count).toBe(1);
    expect(resA.body.post.is_liked).toBe(false);
  });

  test('GET /v1/feed includes like_count and is_liked', async () => {
    // B likes A's post
    await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);

    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenB}`);
    const feedPost = res.body.posts.find((p: any) => p.id === postId);
    expect(feedPost).toBeDefined();
    expect(feedPost.like_count).toBe(1);
    expect(feedPost.is_liked).toBe(true);
  });

  test('GET /v1/feed shows like_count 0 for unliked posts', async () => {
    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenB}`);
    const feedPost = res.body.posts.find((p: any) => p.id === postId);
    expect(feedPost).toBeDefined();
    expect(feedPost.like_count).toBe(0);
    expect(feedPost.is_liked).toBe(false);
  });

  test('GET /v1/posts/by-user/:id includes like_count and is_liked', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);

    const res = await request(app)
      .get(`/v1/posts/by-user/${userA.id}`)
      .set('Authorization', `Bearer ${tokenB}`);
    const userPost = res.body.posts.find((p: any) => p.id === postId);
    expect(userPost).toBeDefined();
    expect(userPost.like_count).toBe(1);
    expect(userPost.is_liked).toBe(true);
  });

  test('Deleting a post cascades to its likes', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/like`)
      .set('Authorization', `Bearer ${tokenB}`);

    await request(app)
      .delete(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenA}`);

    const { rows } = await query(
      'SELECT * FROM post_likes WHERE post_id = $1',
      [postId],
    );
    expect(rows.length).toBe(0);
  });
});

// ==================== AUTO-HIDE POSTS ====================
describe('Auto-hide posts (expires_at)', () => {
  let userA: any, tokenA: string;
  let userB: any, tokenB: string;

  beforeEach(async () => {
    ({ user: userA, token: tokenA } = await createTestUser());
    ({ user: userB, token: tokenB } = await createTestUser());
    await createMutualFollow(userA.id, userB.id);
  });

  test('POST /v1/posts with hide_after_24h sets expires_at', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Ephemeral post',
        media: [{ key: 'photo.jpg', media_type: 'photo', position: 0 }],
        hide_after_24h: true,
      });
    expect(res.status).toBe(201);
    expect(res.body.post.expires_at).toBeDefined();
    const expiresAt = new Date(res.body.post.expires_at);
    const now = new Date();
    // expires_at should be ~24 hours from now (within a minute tolerance)
    const diffHours = (expiresAt.getTime() - now.getTime()) / (1000 * 60 * 60);
    expect(diffHours).toBeGreaterThan(23);
    expect(diffHours).toBeLessThan(25);
  });

  test('POST /v1/posts without hide_after_24h has null expires_at', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Normal post',
        media: [{ key: 'photo.jpg', media_type: 'photo', position: 0 }],
      });
    expect(res.status).toBe(201);
    expect(res.body.post.expires_at).toBeNull();
  });

  test('Expired posts are hidden from feed', async () => {
    // Create a post and manually expire it
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Will expire',
        media: [{ key: 'photo.jpg', media_type: 'photo', position: 0 }],
        hide_after_24h: true,
      });
    const postId = res.body.post.id;

    // Manually set expires_at to the past
    await query(
      "UPDATE posts SET expires_at = NOW() - INTERVAL '1 hour' WHERE id = $1",
      [postId],
    );

    // Feed should not include the expired post for other users
    const feedRes = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenB}`);
    expect(feedRes.status).toBe(200);
    const found = feedRes.body.posts.find((p: any) => p.id === postId);
    expect(found).toBeUndefined();
  });

  test('Author can still see own expired posts via by-user', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'My ephemeral post',
        media: [{ key: 'photo.jpg', media_type: 'photo', position: 0 }],
        hide_after_24h: true,
      });
    const postId = res.body.post.id;

    // Manually expire it
    await query(
      "UPDATE posts SET expires_at = NOW() - INTERVAL '1 hour' WHERE id = $1",
      [postId],
    );

    // Author should still see it
    const userPostsRes = await request(app)
      .get(`/v1/posts/by-user/${userA.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(userPostsRes.status).toBe(200);
    const found = userPostsRes.body.posts.find((p: any) => p.id === postId);
    expect(found).toBeDefined();
  });

  test('Author can still view own expired post by ID', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Expires soon',
        media: [{ key: 'photo.jpg', media_type: 'photo', position: 0 }],
        hide_after_24h: true,
      });
    const postId = res.body.post.id;

    await query(
      "UPDATE posts SET expires_at = NOW() - INTERVAL '1 hour' WHERE id = $1",
      [postId],
    );

    // Author can view
    const getRes = await request(app)
      .get(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(getRes.status).toBe(200);
    expect(getRes.body.post.id).toBe(postId);
  });

  test('Non-author cannot view expired post by ID', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Expires soon',
        media: [{ key: 'photo.jpg', media_type: 'photo', position: 0 }],
        hide_after_24h: true,
      });
    const postId = res.body.post.id;

    await query(
      "UPDATE posts SET expires_at = NOW() - INTERVAL '1 hour' WHERE id = $1",
      [postId],
    );

    // Other user cannot view
    const getRes = await request(app)
      .get(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(getRes.status).toBe(404);
  });

  test('Non-expired posts with expires_at are visible in feed', async () => {
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Still visible',
        media: [{ key: 'photo.jpg', media_type: 'photo', position: 0 }],
        hide_after_24h: true,
      });
    const postId = res.body.post.id;

    // Post has expires_at set but hasn't expired yet — should be visible
    const feedRes = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenB}`);
    expect(feedRes.status).toBe(200);
    const found = feedRes.body.posts.find((p: any) => p.id === postId);
    expect(found).toBeDefined();
  });
});

// ==================== GROUP-SCOPED POSTS ====================
describe('Group-scoped posts', () => {
  test('Group-scoped post is only visible to group members', async () => {
    const { user: owner, token: ownerToken } = await createTestUser();
    const { user: memberUser, token: memberToken } = await createTestUser();
    const { user: outsider, token: outsiderToken } = await createTestUser();

    await createMutualFollow(owner.id, memberUser.id);
    await createMutualFollow(owner.id, outsider.id);

    // Owner creates a group and adds memberUser
    const groupRes = await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ name: 'Close Friends' });
    const groupId = groupRes.body.group.id;

    await request(app)
      .put(`/v1/groups/${groupId}/members`)
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ user_ids: [memberUser.id] });

    // Owner creates a group-scoped post
    const postRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({
        caption: 'Secret post',
        media: [{ key: 'secret.jpg', media_type: 'photo', position: 0 }],
        group_ids: [groupId],
      });
    expect(postRes.status).toBe(201);

    // Member can see it in feed
    const memberFeed = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${memberToken}`);
    const visiblePost = memberFeed.body.posts.find(
      (p: any) => p.id === postRes.body.post.id,
    );
    expect(visiblePost).toBeDefined();

    // Outsider cannot see it in feed
    const outsiderFeed = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${outsiderToken}`);
    const hiddenPost = outsiderFeed.body.posts.find(
      (p: any) => p.id === postRes.body.post.id,
    );
    expect(hiddenPost).toBeUndefined();
  });
});

// ==================== POST REACTIONS ====================
describe('Post Reactions', () => {
  let userA: any, tokenA: string;
  let userB: any, tokenB: string;
  let userC: any, tokenC: string;
  let outsider: any, outsiderToken: string;
  let postId: string;

  beforeEach(async () => {
    ({ user: userA, token: tokenA } = await createTestUser());
    ({ user: userB, token: tokenB } = await createTestUser());
    ({ user: userC, token: tokenC } = await createTestUser());
    ({ user: outsider, token: outsiderToken } = await createTestUser());
    await createMutualFollow(userA.id, userB.id);
    await createMutualFollow(userA.id, userC.id);
    // outsider is NOT mutual with anyone — uses for visibility tests.

    const postRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Reaction test',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });
    postId = postRes.body.post.id;
  });

  test('POST .../reactions/toggle adds a reaction', async () => {
    const res = await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '🔥' });
    expect(res.status).toBe(200);
    expect(res.body.reacted).toBe(true);
    expect(res.body.reactions).toEqual([
      { emoji: '🔥', count: 1, reacted_by_me: true },
    ]);
  });

  test('Toggling the same emoji twice removes it', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '🔥' });

    const res = await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '🔥' });
    expect(res.status).toBe(200);
    expect(res.body.reacted).toBe(false);
    expect(res.body.reactions).toEqual([]);
  });

  test('Same user can add MULTIPLE different emojis on one post', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '🔥' });
    const res = await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '❤️' });
    expect(res.status).toBe(200);
    expect(res.body.reactions.length).toBe(2);
    const byEmoji = Object.fromEntries(
      res.body.reactions.map((r: any) => [r.emoji, r]),
    );
    expect(byEmoji['🔥'].count).toBe(1);
    expect(byEmoji['❤️'].count).toBe(1);
    expect(byEmoji['🔥'].reacted_by_me).toBe(true);
    expect(byEmoji['❤️'].reacted_by_me).toBe(true);
  });

  test('Different users adding the same emoji aggregates the count', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '🔥' });
    const res = await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenC}`)
      .send({ emoji: '🔥' });
    expect(res.body.reactions[0].count).toBe(2);
    expect(res.body.reactions[0].reacted_by_me).toBe(true);
  });

  test('Rejects non-emoji input', async () => {
    for (const bad of ['hello', '', '   ', '🔥🎉', null, 42, '\n']) {
      const res = await request(app)
        .post(`/v1/posts/${postId}/reactions/toggle`)
        .set('Authorization', `Bearer ${tokenB}`)
        .send({ emoji: bad });
      expect(res.status).toBe(400);
    }
  });

  test('Outsider (no mutual follow) gets normalized 404', async () => {
    const res = await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${outsiderToken}`)
      .send({ emoji: '🔥' });
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Post not found');
  });

  test('GET .../reactions/:emoji/users lists users for that emoji', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '🔥' });
    await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenC}`)
      .send({ emoji: '🔥' });

    const res = await request(app)
      .get(`/v1/posts/${postId}/reactions/${encodeURIComponent('🔥')}/users`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.users.length).toBe(2);
    const ids = res.body.users.map((u: any) => u.id).sort();
    expect(ids).toEqual([userB.id, userC.id].sort());
  });

  test('GET .../reactions/:emoji/users gates on visibility', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '🔥' });

    const res = await request(app)
      .get(`/v1/posts/${postId}/reactions/${encodeURIComponent('🔥')}/users`)
      .set('Authorization', `Bearer ${outsiderToken}`);
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Post not found');
  });

  test('GET /v1/feed enriches each post with reactions array', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '🔥' });

    const feedRes = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenA}`);
    const feedPost = feedRes.body.posts.find((p: any) => p.id === postId);
    expect(feedPost).toBeDefined();
    expect(feedPost.reactions).toEqual([
      { emoji: '🔥', count: 1, reacted_by_me: false },
    ]);
  });

  test('GET /v1/posts/:id enriches with reactions array', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/reactions/toggle`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ emoji: '🎉' });

    const res = await request(app)
      .get(`/v1/posts/${postId}`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(res.body.post.reactions).toEqual([
      { emoji: '🎉', count: 1, reacted_by_me: true },
    ]);
  });
});

// ==================== COMMENTS ====================
describe('Comments', () => {
  let userA: any, tokenA: string;
  let userB: any, tokenB: string;
  let postId: string;

  beforeEach(async () => {
    ({ user: userA, token: tokenA } = await createTestUser());
    ({ user: userB, token: tokenB } = await createTestUser());
    await createMutualFollow(userA.id, userB.id);

    const postRes = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'Comment test',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });
    postId = postRes.body.post.id;
  });

  test('POST /v1/posts/:id/comments creates comment', async () => {
    const res = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Nice photo!' });
    expect(res.status).toBe(201);
    expect(res.body.comment.body).toBe('Nice photo!');
  });

  test('GET /v1/posts/:id/comments lists comments', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Comment 1' });

    await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'Comment 2' });

    const res = await request(app)
      .get(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.comments.length).toBe(2);
  });

  test('DELETE /v1/comments/:id soft-deletes and hides from listing', async () => {
    const createRes = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'To delete' });

    const res = await request(app)
      .delete(`/v1/comments/${createRes.body.comment.id}`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(res.status).toBe(200);

    // Soft-delete is preserved in the DB (deleted_at set, body marker
    // intact for any future moderator/audit use), but the public
    // listing endpoint must NOT return it. Previously we rendered a
    // literal "[deleted]" placeholder which was confusing visual noise.
    const listRes = await request(app)
      .get(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`);
    const deletedInList = listRes.body.comments.find(
      (c: any) => c.id === createRes.body.comment.id,
    );
    expect(deletedInList).toBeUndefined();

    // Verify the row is still in the DB with deleted_at set — the
    // listing filter is the only thing hiding it.
    const { rows } = await query(
      'SELECT body, deleted_at FROM comments WHERE id = $1',
      [createRes.body.comment.id],
    );
    expect(rows[0].deleted_at).not.toBeNull();
  });

  test('Replies to a deleted comment are also hidden from listing', async () => {
    // Parent comment by user B
    const parentRes = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Parent that will be deleted' });
    const parentId = parentRes.body.comment.id;

    // Reply by user A pointing at the parent
    const replyRes = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'Reply to parent', reply_to_comment_id: parentId });
    const replyId = replyRes.body.comment.id;

    // Both visible before delete
    let listRes = await request(app)
      .get(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(listRes.body.comments.find((c: any) => c.id === parentId)).toBeDefined();
    expect(listRes.body.comments.find((c: any) => c.id === replyId)).toBeDefined();

    // Delete the parent
    await request(app)
      .delete(`/v1/comments/${parentId}`)
      .set('Authorization', `Bearer ${tokenB}`);

    // Both parent and reply should now be gone — replies orphaned
    // by a deleted parent are hidden too so the thread doesn't
    // dangle in the UI.
    listRes = await request(app)
      .get(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(listRes.body.comments.find((c: any) => c.id === parentId)).toBeUndefined();
    expect(listRes.body.comments.find((c: any) => c.id === replyId)).toBeUndefined();
  });

  test('Rejects comment over 1000 chars', async () => {
    const res = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'x'.repeat(1001) });
    expect(res.status).toBe(400);
  });

  test('Non-mutual cannot comment', async () => {
    const { token: strangerToken } = await createTestUser();
    const res = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${strangerToken}`)
      .send({ body: 'Sneaky comment' });
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Post not found');
  });

  test('PUT /v1/comments/:id edits own comment', async () => {
    const createRes = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Original comment' });
    expect(createRes.status).toBe(201);

    const commentId = createRes.body.comment.id;
    const editRes = await request(app)
      .put(`/v1/comments/${commentId}`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Edited comment' });
    expect(editRes.status).toBe(200);
    expect(editRes.body.comment.body).toBe('Edited comment');
    expect(editRes.body.comment.updated_at).toBeDefined();
  });

  test('PUT /v1/comments/:id rejects editing other users comment', async () => {
    const createRes = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Their comment' });
    const commentId = createRes.body.comment.id;

    const editRes = await request(app)
      .put(`/v1/comments/${commentId}`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'Hijacked!' });
    expect(editRes.status).toBe(404);
  });

  test('PUT /v1/comments/:id rejects editing deleted comment', async () => {
    const createRes = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'To delete then edit' });
    const commentId = createRes.body.comment.id;

    await request(app)
      .delete(`/v1/comments/${commentId}`)
      .set('Authorization', `Bearer ${tokenB}`);

    const editRes = await request(app)
      .put(`/v1/comments/${commentId}`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Edited after delete' });
    expect(editRes.status).toBe(404);
  });

  // ── Reply notifications ──────────────────────────────────────────
  //
  // These exercise the dedup rules in src/routes/comments.ts. Assertions
  // hit the `notifications` table directly since FCM is fire-and-forget
  // and not mocked in this suite.

  async function notifsFor(userId: string) {
    const { rows } = await query(
      `SELECT type, actor_id, reference_id, reference_type
       FROM notifications WHERE user_id = $1 ORDER BY created_at ASC`,
      [userId],
    );
    return rows;
  }

  test('Reply: B comments on A post → A gets comment notification', async () => {
    const res = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'hi' });
    expect(res.status).toBe(201);
    const rows = await notifsFor(userA.id);
    expect(rows.length).toBe(1);
    expect(rows[0].type).toBe('comment');
    expect(rows[0].actor_id).toBe(userB.id);
    expect(rows[0].reference_id).toBe(res.body.comment.id);
    expect(rows[0].reference_type).toBe('comment');
  });

  test('Reply: A comments on own post → no notifications', async () => {
    await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'self' });
    expect((await notifsFor(userA.id)).length).toBe(0);
  });

  test('Reply: C replies to B on A post → A:comment, B:comment_reply', async () => {
    const { user: userC, token: tokenC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    const first = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'B comment' });
    expect(first.status).toBe(201);

    const second = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenC}`)
      .send({ body: '@B hey', reply_to_comment_id: first.body.comment.id });
    expect(second.status).toBe(201);

    const aNotifs = await notifsFor(userA.id);
    // A gets: B's original comment + C's reply (as post author)
    expect(aNotifs.length).toBe(2);
    expect(aNotifs.map((r) => r.type).sort()).toEqual(['comment', 'comment']);

    const bNotifs = await notifsFor(userB.id);
    expect(bNotifs.length).toBe(1);
    expect(bNotifs[0].type).toBe('comment_reply');
    expect(bNotifs[0].actor_id).toBe(userC.id);
    expect(bNotifs[0].reference_id).toBe(second.body.comment.id);
  });

  test('Reply: A replies to B on A own post → B:comment_reply only', async () => {
    const first = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'B comment' });

    await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: '@B thanks', reply_to_comment_id: first.body.comment.id });

    const bNotifs = await notifsFor(userB.id);
    const replyOnes = bNotifs.filter((r) => r.type === 'comment_reply');
    expect(replyOnes.length).toBe(1);
    expect(replyOnes[0].actor_id).toBe(userA.id);
  });

  test('Reply: B replies to own prior comment on A post → A:comment, B:none', async () => {
    const first = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'first' });

    await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'second', reply_to_comment_id: first.body.comment.id });

    const aNotifs = await notifsFor(userA.id);
    expect(aNotifs.length).toBe(2); // both original + self-reply still notify A
    expect(aNotifs.every((r) => r.type === 'comment')).toBe(true);

    const bNotifs = await notifsFor(userB.id);
    // no self-notifications even when replying to yourself
    expect(bNotifs.length).toBe(0);
  });

  test('Reply: C replies to A comment on A post → A:comment_reply only (dedup)', async () => {
    // A comments on own post (no notification yet)
    const aComment = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'A self-comment' });
    expect((await notifsFor(userA.id)).length).toBe(0);

    // C (mutual) replies to A's comment. A is BOTH post author and parent
    // author — should get exactly one notification, typed comment_reply.
    const { user: userC, token: tokenC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenC}`)
      .send({ body: '@A hi', reply_to_comment_id: aComment.body.comment.id });

    const rows = await notifsFor(userA.id);
    expect(rows.length).toBe(1);
    expect(rows[0].type).toBe('comment_reply');
    expect(rows[0].actor_id).toBe(userC.id);
  });

  test('Reply: A replies to own comment on own post → no notifications', async () => {
    const aComment = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'self 1' });

    await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'self 2', reply_to_comment_id: aComment.body.comment.id });

    expect((await notifsFor(userA.id)).length).toBe(0);
  });

  test('Reply: cross-post reply_to_comment_id → 400', async () => {
    const otherPost = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        caption: 'other post',
        media: [{ key: 'img2.jpg', media_type: 'photo', position: 0 }],
      });
    const otherPostId = otherPost.body.post.id;

    const otherComment = await request(app)
      .post(`/v1/posts/${otherPostId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'on other post' });

    const res = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'wrong post', reply_to_comment_id: otherComment.body.comment.id });
    expect(res.status).toBe(400);
  });

  test('Reply: parent soft-deleted → 400', async () => {
    const parent = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'soon to delete' });

    await request(app)
      .delete(`/v1/comments/${parent.body.comment.id}`)
      .set('Authorization', `Bearer ${tokenB}`);

    const res = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'reply to dead', reply_to_comment_id: parent.body.comment.id });
    expect(res.status).toBe(400);
  });

  test('Reply: parent UUID malformed → 400', async () => {
    const res = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'bad uuid', reply_to_comment_id: 'not-a-uuid' });
    expect(res.status).toBe(400);
  });

  test('Reply: GET exposes reply_to_display_name for replies, null for top-level', async () => {
    const parent = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'parent' });

    await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'child', reply_to_comment_id: parent.body.comment.id });

    const list = await request(app)
      .get(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(list.status).toBe(200);
    const parentRow = list.body.comments.find((c: any) => c.id === parent.body.comment.id);
    const childRow = list.body.comments.find((c: any) => c.id !== parent.body.comment.id);
    expect(parentRow.reply_to_comment_id).toBeNull();
    expect(parentRow.reply_to_display_name).toBeNull();
    expect(parentRow.reply_to_user_id).toBeNull();
    expect(childRow.reply_to_comment_id).toBe(parent.body.comment.id);
    expect(childRow.reply_to_display_name).toBe(userB.display_name);
    expect(childRow.reply_to_user_id).toBe(userB.id);
  });

  test('Reply: notifications reference_id points at new comment id with reference_type=comment', async () => {
    const parent = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'parent' });
    // Also verifies the existing comment (not reply) notif now uses
    // reference_type='comment' and reference_id=comment id (was 'post'/postId).
    const aNotifs = await notifsFor(userA.id);
    expect(aNotifs[0].reference_type).toBe('comment');
    expect(aNotifs[0].reference_id).toBe(parent.body.comment.id);
  });

  // ── Comment likes ────────────────────────────────────────────────
  //
  // Mirrors the post-like pattern end-to-end: idempotent toggle, count
  // + is_liked on list, unlike is safe to call twice.

  test('Like: POST /v1/comments/:id/like adds a like and returns count', async () => {
    const create = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'likeable' });

    const res = await request(app)
      .post(`/v1/comments/${create.body.comment.id}/like`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.liked).toBe(true);
    expect(res.body.like_count).toBe(1);
  });

  test('Like: double-like is idempotent (no 409, count stays 1)', async () => {
    const create = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'once-twice' });

    await request(app)
      .post(`/v1/comments/${create.body.comment.id}/like`)
      .set('Authorization', `Bearer ${tokenA}`);
    const res = await request(app)
      .post(`/v1/comments/${create.body.comment.id}/like`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.like_count).toBe(1);
  });

  test('Like: DELETE removes the like, idempotent on second call', async () => {
    const create = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'unlikeable' });
    const id = create.body.comment.id;

    await request(app)
      .post(`/v1/comments/${id}/like`)
      .set('Authorization', `Bearer ${tokenA}`);
    const first = await request(app)
      .delete(`/v1/comments/${id}/like`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(first.status).toBe(200);
    expect(first.body.liked).toBe(false);
    expect(first.body.like_count).toBe(0);

    // Second unlike is a no-op, still 200
    const second = await request(app)
      .delete(`/v1/comments/${id}/like`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(second.status).toBe(200);
    expect(second.body.like_count).toBe(0);
  });

  test('Like: POST on a non-existent comment returns 404', async () => {
    const res = await request(app)
      .post('/v1/comments/00000000-0000-0000-0000-000000000000/like')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(404);
  });

  test('Like: GET comments exposes is_liked per-user and like_count total', async () => {
    const c1 = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'likes test' });

    // userA likes it, userB doesn't
    await request(app)
      .post(`/v1/comments/${c1.body.comment.id}/like`)
      .set('Authorization', `Bearer ${tokenA}`);

    const asA = await request(app)
      .get(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenA}`);
    const rowForA = asA.body.comments.find((c: any) => c.id === c1.body.comment.id);
    expect(rowForA.is_liked).toBe(true);
    expect(rowForA.like_count).toBe(1);

    const asB = await request(app)
      .get(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`);
    const rowForB = asB.body.comments.find((c: any) => c.id === c1.body.comment.id);
    expect(rowForB.is_liked).toBe(false);
    expect(rowForB.like_count).toBe(1);
  });

  test('Like: delete-cascade — deleting the comment removes its likes', async () => {
    const c1 = await request(app)
      .post(`/v1/posts/${postId}/comments`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'doomed' });
    await request(app)
      .post(`/v1/comments/${c1.body.comment.id}/like`)
      .set('Authorization', `Bearer ${tokenA}`);

    // Soft-delete keeps the row. To truly test the FK cascade we need
    // a hard delete, which we don't expose via the API — so just verify
    // the response to a like query stays consistent for soft-deleted
    // comments (the /like endpoint returns 404 on soft-deleted).
    await request(app)
      .delete(`/v1/comments/${c1.body.comment.id}`)
      .set('Authorization', `Bearer ${tokenB}`);

    const res = await request(app)
      .post(`/v1/comments/${c1.body.comment.id}/like`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(404);
  });
});

// ==================== STORIES ====================
describe('Stories', () => {
  test('POST /v1/stories creates a story', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/stories')
      .set('Authorization', `Bearer ${token}`)
      .send({ key: 'story-test.jpg', media_type: 'photo' });
    expect(res.status).toBe(201);
    expect(res.body.story.expires_at).toBeDefined();
  });

  test('GET /v1/stories returns mutual follow stories', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b, token: tokenB } = await createTestUser();
    await createMutualFollow(a.id, b.id);

    await request(app)
      .post('/v1/stories')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ key: 'story-test.jpg', media_type: 'photo' });

    const res = await request(app)
      .get('/v1/stories')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.story_groups.length).toBeGreaterThanOrEqual(1);
  });

  test('DELETE /v1/stories/:id deletes story', async () => {
    const { token } = await createTestUser();
    const createRes = await request(app)
      .post('/v1/stories')
      .set('Authorization', `Bearer ${token}`)
      .send({ key: 'story-test.jpg', media_type: 'photo' });

    const res = await request(app)
      .delete(`/v1/stories/${createRes.body.story.id}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
  });

  test('POST /v1/stories/upload-url returns presigned URL', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/stories/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({ content_type: 'image/jpeg' });
    expect(res.status).toBe(200);
    expect(res.body.upload_url).toBeDefined();
    expect(res.body.key).toBeDefined();
  });
});

// ==================== CONVERSATIONS & DMs ====================
describe('Conversations', () => {
  let userA: any, tokenA: string;
  let userB: any, tokenB: string;

  beforeEach(async () => {
    ({ user: userA, token: tokenA } = await createTestUser());
    ({ user: userB, token: tokenB } = await createTestUser());
    await createMutualFollow(userA.id, userB.id);
  });

  test('POST /v1/conversations creates conversation', async () => {
    const res = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });
    expect(res.status).toBe(201);
    expect(res.body.conversation).toBeDefined();
    expect(res.body.conversation.other_user_id).toBe(userB.id);
    expect(res.body.conversation.other_display_name).toBeDefined();
    expect(res.body.conversation.unread_count).toBe(0);
  });

  test('POST /v1/conversations returns existing conversation', async () => {
    const res1 = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });

    const res2 = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ user_id: userA.id });

    expect(res2.status).toBe(200);
    expect(res2.body.conversation.id).toBe(res1.body.conversation.id);
  });

  test('Cannot create conversation without mutual follow', async () => {
    const { token: strangerToken } = await createTestUser();
    const res = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${strangerToken}`)
      .send({ user_id: userA.id });
    expect(res.status).toBe(403);
  });

  test('POST /v1/conversations/:id/messages sends message', async () => {
    const convRes = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });

    const res = await request(app)
      .post(`/v1/conversations/${convRes.body.conversation.id}/messages`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'Hello!' });
    expect(res.status).toBe(201);
    expect(res.body.message.body).toBe('Hello!');
  });

  test('GET /v1/conversations/:id/messages returns messages', async () => {
    const convRes = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });
    const convId = convRes.body.conversation.id;

    await request(app)
      .post(`/v1/conversations/${convId}/messages`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'Message 1' });

    await request(app)
      .post(`/v1/conversations/${convId}/messages`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Message 2' });

    const res = await request(app)
      .get(`/v1/conversations/${convId}/messages`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.messages.length).toBe(2);
  });

  test('GET /v1/conversations lists conversations with unread count', async () => {
    const convRes = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });

    // B sends a message
    await request(app)
      .post(`/v1/conversations/${convRes.body.conversation.id}/messages`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Unread message' });

    const res = await request(app)
      .get('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.conversations.length).toBeGreaterThanOrEqual(1);
    const conv = res.body.conversations.find(
      (c: any) => c.id === convRes.body.conversation.id,
    );
    expect(parseInt(conv.unread_count)).toBeGreaterThanOrEqual(1);
  });

  test('POST /v1/conversations/:id/read marks as read', async () => {
    const convRes = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });
    const convId = convRes.body.conversation.id;

    await request(app)
      .post(`/v1/conversations/${convId}/messages`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ body: 'Read me' });

    const res = await request(app)
      .post(`/v1/conversations/${convId}/read`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);

    // Unread count should now be 0
    const listRes = await request(app)
      .get('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`);
    const conv = listRes.body.conversations.find((c: any) => c.id === convId);
    expect(parseInt(conv.unread_count)).toBe(0);
  });

  test('GET /v1/conversations does not return empty conversations', async () => {
    // Create conversation without sending any message
    await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });

    // Listing should not include it (no messages sent)
    const res = await request(app)
      .get('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.conversations.length).toBe(0);
  });

  // Parallel to the direct-message test above, specifically for the
  // group-DM path. Build 35 moved group creation to be lazy on the
  // client (no server row until first message sent), but defense in
  // depth: if any older client still eager-creates, the server must
  // still hide the empty row. Regression fence for the earlier bug
  // where an eager-created group showed "Chat" in the AppBar because
  // it couldn't find itself in the filtered list.
  test('GET /v1/conversations hides empty group DMs (no messages sent)', async () => {
    const { user: userC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    const createRes = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Empty Group' });
    expect(createRes.status).toBe(201);
    const emptyGroupId = createRes.body.conversation.id;

    const listRes = await request(app)
      .get('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(listRes.status).toBe(200);
    expect(
      listRes.body.conversations.some((c: any) => c.id === emptyGroupId),
    ).toBe(false);
  });

  test('GET /v1/conversations returns conversation after message is sent', async () => {
    const convRes = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });
    const convId = convRes.body.conversation.id;

    // Send a message
    await request(app)
      .post(`/v1/conversations/${convId}/messages`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'Hey!' });

    // Now it should appear
    const res = await request(app)
      .get('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.conversations.length).toBeGreaterThanOrEqual(1);
    expect(res.body.conversations.some((c: any) => c.id === convId)).toBe(true);
  });

  // ── Group DMs (Phase 0) ──────────────────────────────────────────
  //
  // Plaintext group chat. Same access model as directs (members only can
  // read/send), plus creator-only controls for membership and rename.

  test('Group: POST /v1/conversations with member_ids creates a group', async () => {
    const { user: userC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    const res = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Weekend' });
    expect(res.status).toBe(201);
    expect(res.body.conversation.conversation_type).toBe('group');
    expect(res.body.conversation.name).toBe('Weekend');
    expect(res.body.conversation.created_by).toBe(userA.id);
    expect(res.body.conversation.members.length).toBe(3);
    expect(res.body.conversation.user_a_id).toBeNull();
    expect(res.body.conversation.user_b_id).toBeNull();
  });

  test('Group: creation requires name', async () => {
    const res = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id] });
    expect(res.status).toBe(400);
  });

  test('Group: creation rejects name over 50 chars', async () => {
    const res = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'x'.repeat(51) });
    expect(res.status).toBe(400);
  });

  test('Group: creation caps at 10 total members', async () => {
    // creator + 10 others = 11
    const extras = await Promise.all(
      Array.from({ length: 10 }, () => createTestUser()),
    );
    for (const e of extras) {
      await createMutualFollow(userA.id, e.user.id);
    }
    const res = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        member_ids: extras.map((e) => e.user.id),
        name: 'Too Many',
      });
    expect(res.status).toBe(400);
  });

  test('Group: creation rejects non-mutual members', async () => {
    const { user: stranger } = await createTestUser();
    const res = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, stranger.id], name: 'Mixed' });
    expect(res.status).toBe(403);
  });

  test('Group: non-members cannot read messages', async () => {
    const { user: userC, token: tokenC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);
    const { token: strangerToken } = await createTestUser();

    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Chat' });

    await request(app)
      .post(`/v1/conversations/${group.body.conversation.id}/messages`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'Hello group' });

    const res = await request(app)
      .get(`/v1/conversations/${group.body.conversation.id}/messages`)
      .set('Authorization', `Bearer ${strangerToken}`);
    expect(res.status).toBe(403);
    expect(tokenC).toBeDefined(); // silence unused
  });

  test('Group: message fan out — all N-1 others get notifications', async () => {
    const { user: userC, token: tokenC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Fanout' });

    await request(app)
      .post(`/v1/conversations/${group.body.conversation.id}/messages`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'Hi all' });

    const { rows: bNotifs } = await query(
      `SELECT * FROM notifications WHERE user_id = $1 AND type = 'dm' AND actor_id = $2`,
      [userB.id, userA.id],
    );
    const { rows: cNotifs } = await query(
      `SELECT * FROM notifications WHERE user_id = $1 AND type = 'dm' AND actor_id = $2`,
      [userC.id, userA.id],
    );
    expect(bNotifs.length).toBe(1);
    expect(cNotifs.length).toBe(1);
    // Sender gets nothing
    const { rows: aNotifs } = await query(
      `SELECT * FROM notifications WHERE user_id = $1 AND type = 'dm' AND actor_id = $1`,
      [userA.id],
    );
    expect(aNotifs.length).toBe(0);
    expect(tokenC).toBeDefined();
  });

  test('Group: PATCH renames (creator only)', async () => {
    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'Original' });

    const res = await request(app)
      .patch(`/v1/conversations/${group.body.conversation.id}`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ name: 'Renamed' });
    expect(res.status).toBe(200);
    expect(res.body.conversation.name).toBe('Renamed');

    // Non-creator forbidden
    const forbidden = await request(app)
      .patch(`/v1/conversations/${group.body.conversation.id}`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ name: 'Hijacked' });
    expect(forbidden.status).toBe(403);
  });

  test('Group: PATCH rejects on direct conversation', async () => {
    const direct = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });

    const res = await request(app)
      .patch(`/v1/conversations/${direct.body.conversation.id}`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ name: 'Nope' });
    expect(res.status).toBe(400);
  });

  test('Group: add and remove members (creator only)', async () => {
    const { user: userC } = await createTestUser();
    const { user: userD } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);
    await createMutualFollow(userA.id, userD.id);

    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'Start small' });
    const gid = group.body.conversation.id;

    // Add C
    const add = await request(app)
      .post(`/v1/conversations/${gid}/members`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_ids: [userC.id] });
    expect(add.status).toBe(200);
    expect(add.body.conversation.members.length).toBe(3);

    // Non-creator can't add
    const forbidden = await request(app)
      .post(`/v1/conversations/${gid}/members`)
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ user_ids: [userD.id] });
    expect(forbidden.status).toBe(403);

    // Remove C
    const rm = await request(app)
      .delete(`/v1/conversations/${gid}/members/${userC.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(rm.status).toBe(200);

    // Creator can't remove self via DELETE (must use /leave)
    const selfRemove = await request(app)
      .delete(`/v1/conversations/${gid}/members/${userA.id}`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(selfRemove.status).toBe(400);
  });

  test('Group: adding over cap returns 400', async () => {
    // Start with 9 members total (creator + userB + 7 extras = 9). Cap is 10.
    const extras = await Promise.all(
      Array.from({ length: 7 }, () => createTestUser()),
    );
    for (const e of extras) {
      await createMutualFollow(userA.id, e.user.id);
    }
    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({
        member_ids: [userB.id, ...extras.map((e) => e.user.id)],
        name: 'Nine',
      });
    expect(group.body.conversation.members.length).toBe(9);

    // Try to add 2 more (would make 11)
    const { user: u1 } = await createTestUser();
    const { user: u2 } = await createTestUser();
    await createMutualFollow(userA.id, u1.id);
    await createMutualFollow(userA.id, u2.id);

    const res = await request(app)
      .post(`/v1/conversations/${group.body.conversation.id}/members`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_ids: [u1.id, u2.id] });
    expect(res.status).toBe(400);
  });

  test('Group: leave keeps conversation alive while others remain', async () => {
    const { user: userC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Leave test' });
    const gid = group.body.conversation.id;

    const res = await request(app)
      .post(`/v1/conversations/${gid}/leave`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(res.status).toBe(200);
    expect(res.body.dissolved).toBe(false);

    // Conversation still exists; userB should no longer be a member
    const { rows: members } = await query(
      'SELECT user_id FROM conversation_members WHERE conversation_id = $1',
      [gid],
    );
    expect(members.map((m: any) => m.user_id).sort()).toEqual(
      [userA.id, userC.id].sort(),
    );
  });

  test('Group: last member leaving dissolves the conversation', async () => {
    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'Doomed' });
    const gid = group.body.conversation.id;

    // Both leave
    await request(app)
      .post(`/v1/conversations/${gid}/leave`)
      .set('Authorization', `Bearer ${tokenB}`);
    const last = await request(app)
      .post(`/v1/conversations/${gid}/leave`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(last.status).toBe(200);
    expect(last.body.dissolved).toBe(true);

    const { rows } = await query('SELECT 1 FROM conversations WHERE id = $1', [gid]);
    expect(rows.length).toBe(0);
  });

  test('Group: leave rejects for direct conversation', async () => {
    const direct = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: userB.id });

    const res = await request(app)
      .post(`/v1/conversations/${direct.body.conversation.id}/leave`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(400);
  });

  test('Group: GET /conversations includes members[] and null other_*', async () => {
    const { user: userC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Listing' });

    await request(app)
      .post(`/v1/conversations/${group.body.conversation.id}/messages`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'kickoff' });

    const list = await request(app)
      .get('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`);
    const found = list.body.conversations.find(
      (c: any) => c.id === group.body.conversation.id,
    );
    expect(found).toBeDefined();
    expect(found.conversation_type).toBe('group');
    expect(found.name).toBe('Listing');
    expect(Array.isArray(found.members)).toBe(true);
    expect(found.members.length).toBe(3);
    expect(found.other_user_id).toBeNull();
  });

  // ── Admin transfer on leave ──────────────────────────────────────
  //
  // Creator leaving with others still in the group must hand off admin.
  // Non-creators leave freely. Sole-member leaves dissolve the group
  // without any transfer (the conversation is going away anyway).

  test('Admin: creator leave without new_admin_id returns 400 + hint', async () => {
    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'Transfer' });

    const res = await request(app)
      .post(`/v1/conversations/${group.body.conversation.id}/leave`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(400);
    expect(res.body.requires_admin_transfer).toBe(true);

    // Group + members + creator unchanged.
    const { rows } = await query(
      'SELECT created_by FROM conversations WHERE id = $1',
      [group.body.conversation.id],
    );
    expect(rows[0].created_by).toBe(userA.id);
  });

  test('Admin: creator leave with new_admin_id transfers and leaves atomically', async () => {
    const { user: userC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Handoff' });
    const gid = group.body.conversation.id;

    const res = await request(app)
      .post(`/v1/conversations/${gid}/leave`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ new_admin_id: userC.id });
    expect(res.status).toBe(200);
    expect(res.body.dissolved).toBe(false);

    // created_by is now C; userA no longer a member.
    const { rows: conv } = await query(
      'SELECT created_by FROM conversations WHERE id = $1',
      [gid],
    );
    expect(conv[0].created_by).toBe(userC.id);

    const { rows: members } = await query(
      'SELECT user_id FROM conversation_members WHERE conversation_id = $1',
      [gid],
    );
    const ids = members.map((m: any) => m.user_id).sort();
    expect(ids).toEqual([userB.id, userC.id].sort());
  });

  test('Admin: new_admin_id must be a current member', async () => {
    const { user: userC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);
    const { user: stranger } = await createTestUser();

    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Bad handoff' });

    const res = await request(app)
      .post(`/v1/conversations/${group.body.conversation.id}/leave`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ new_admin_id: stranger.id });
    expect(res.status).toBe(400);
  });

  test('Admin: cannot transfer admin to self', async () => {
    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'Self transfer' });

    const res = await request(app)
      .post(`/v1/conversations/${group.body.conversation.id}/leave`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ new_admin_id: userA.id });
    expect(res.status).toBe(400);
  });

  test('Admin: malformed new_admin_id UUID returns 400', async () => {
    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'Bad UUID' });

    const res = await request(app)
      .post(`/v1/conversations/${group.body.conversation.id}/leave`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ new_admin_id: 'not-a-uuid' });
    expect(res.status).toBe(400);
  });

  test('Admin: non-creator leave does not require new_admin_id', async () => {
    const { user: userC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Non-creator' });

    const res = await request(app)
      .post(`/v1/conversations/${group.body.conversation.id}/leave`)
      .set('Authorization', `Bearer ${tokenB}`);
    expect(res.status).toBe(200);
    expect(res.body.dissolved).toBe(false);
  });

  test('Admin: creator sole leave dissolves group without transfer', async () => {
    // Creator is the only member (e.g. everyone else left first).
    // We set it up by B leaving first.
    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'Sole' });
    const gid = group.body.conversation.id;

    await request(app)
      .post(`/v1/conversations/${gid}/leave`)
      .set('Authorization', `Bearer ${tokenB}`);

    // Now A is alone — can leave without new_admin_id and group dissolves.
    const res = await request(app)
      .post(`/v1/conversations/${gid}/leave`)
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    expect(res.body.dissolved).toBe(true);
  });

  test('Admin: auto-promote on account soft-delete', async () => {
    // Creator created group with B and C. B joined first (earlier timestamp).
    // When creator deletes account, B should inherit created_by.
    const { user: userC } = await createTestUser();
    await createMutualFollow(userA.id, userC.id);

    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id, userC.id], name: 'Auto promote' });
    const gid = group.body.conversation.id;

    // Delete creator's account.
    const del = await request(app)
      .delete('/v1/users/me')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(del.status).toBe(200);

    // created_by should now be userB (oldest joined — B was added first
    // in the member_ids array in createGroup, so joined_at is earlier).
    const { rows } = await query(
      'SELECT created_by FROM conversations WHERE id = $1',
      [gid],
    );
    expect(rows[0].created_by).toBe(userB.id);

    // Creator no longer a member.
    const { rows: members } = await query(
      'SELECT user_id FROM conversation_members WHERE conversation_id = $1',
      [gid],
    );
    const ids = members.map((m: any) => m.user_id).sort();
    expect(ids).toEqual([userB.id, userC.id].sort());
  });

  test('Admin: account delete dissolves sole-creator-sole-member group', async () => {
    // A creates a group with B, then B leaves. A is now sole member.
    // When A deletes their account, the group should be dissolved —
    // not orphaned with a deleted created_by and 0 members.
    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'Lone' });
    const gid = group.body.conversation.id;

    // B leaves, A is now sole member and still the creator.
    await request(app)
      .post(`/v1/conversations/${gid}/leave`)
      .set('Authorization', `Bearer ${tokenB}`);

    // Add a message so we can verify it's also cleaned up.
    await request(app)
      .post(`/v1/conversations/${gid}/messages`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'talking to myself' });

    // A deletes their account.
    const del = await request(app)
      .delete('/v1/users/me')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(del.status).toBe(200);

    // Group, memberships, and messages are all gone.
    const { rows: convs } = await query(
      'SELECT 1 FROM conversations WHERE id = $1',
      [gid],
    );
    expect(convs.length).toBe(0);

    const { rows: msgs } = await query(
      'SELECT 1 FROM messages WHERE conversation_id = $1',
      [gid],
    );
    expect(msgs.length).toBe(0);
  });

  test('Admin: account delete is no-op on groups when user is not a creator', async () => {
    // A creates a group with B. B (non-creator) deletes their account.
    // The group stays, A stays as creator, B is removed from membership.
    const group = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ member_ids: [userB.id], name: 'Member deletes' });
    const gid = group.body.conversation.id;

    const del = await request(app)
      .delete('/v1/users/me')
      .set('Authorization', `Bearer ${tokenB}`);
    expect(del.status).toBe(200);

    // Group still exists, A still creator, B no longer a member.
    const { rows: convs } = await query(
      'SELECT created_by FROM conversations WHERE id = $1',
      [gid],
    );
    expect(convs.length).toBe(1);
    expect(convs[0].created_by).toBe(userA.id);

    const { rows: members } = await query(
      'SELECT user_id FROM conversation_members WHERE conversation_id = $1',
      [gid],
    );
    expect(members.map((m: any) => m.user_id)).toEqual([userA.id]);
  });
});

// ==================== E2EE MESSAGE ENVELOPE (Phase 1d) ====================

describe('E2EE message envelope', () => {
  // Helpers — mutual-follow setup used by every test in this block.
  async function followBoth(a: any, b: any) {
    await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${a.token}`)
      .send({ user_id: b.id });
    await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${b.token}`)
      .send({ user_id: a.id });
  }
  async function openE2eeDirect(a: any, b: any) {
    const res = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${a.token}`)
      .send({ user_id: b.id, is_e2ee: true });
    return res.body.conversation;
  }
  function rb64(n: number) {
    return crypto.randomBytes(n).toString('base64');
  }

  describe('POST /v1/conversations', () => {
    test('is_e2ee: true is persisted on direct conversations', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );

      const conv = await openE2eeDirect(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      expect(conv.is_e2ee).toBe(true);

      // epoch defaults to 0
      expect(conv.epoch).toBe(0);
    });

    test('is_e2ee defaults to false when omitted', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );

      const res = await request(app)
        .post('/v1/conversations')
        .set('Authorization', `Bearer ${alice.token}`)
        .send({ user_id: bob.user.id });
      expect(res.body.conversation.is_e2ee).toBe(false);
    });

    test('is_e2ee: true works on group conversations', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const carol = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: carol.token, id: carol.user.id },
      );

      const res = await request(app)
        .post('/v1/conversations')
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          name: 'Encrypted crew',
          member_ids: [bob.user.id, carol.user.id],
          is_e2ee: true,
        });
      expect(res.status).toBe(201);
      expect(res.body.conversation.is_e2ee).toBe(true);
    });

    test('conversation_members default joined_at_epoch to 0', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      const conv = await openE2eeDirect(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );

      const { rows } = await query(
        'SELECT joined_at_epoch FROM conversation_members WHERE conversation_id = $1',
        [conv.id],
      );
      expect(rows.length).toBe(2);
      expect(rows.every((r: any) => r.joined_at_epoch === 0)).toBe(true);
    });
  });

  describe('POST /v1/conversations/:id/messages', () => {
    test('E2EE conv: stores ciphertext and envelope_type', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      const conv = await openE2eeDirect(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );

      const ciphertext = rb64(96);
      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext,
          envelope_type: 'signal_1to1',
          protocol_version: 1,
        });
      expect(res.status).toBe(201);
      expect(res.body.message.envelope_type).toBe('signal_1to1');
      expect(res.body.message.protocol_version).toBe(1);
      expect(res.body.message.ciphertext).toBe(ciphertext);
      expect(res.body.message.body).toBeNull();

      // DB: bytea column round-trips
      const { rows } = await query(
        'SELECT ciphertext, envelope_type FROM messages WHERE id = $1',
        [res.body.message.id],
      );
      expect(rows[0].envelope_type).toBe('signal_1to1');
      expect(Buffer.from(rows[0].ciphertext).toString('base64')).toBe(
        ciphertext,
      );
    });

    test('E2EE conv: rejects plaintext body with 400', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      const conv = await openE2eeDirect(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({ body: 'hi there' });
      expect(res.status).toBe(400);
      expect(res.body.error).toMatch(/ciphertext/i);
    });

    test('E2EE conv: rejects missing ciphertext', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      const conv = await openE2eeDirect(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({ envelope_type: 'signal_1to1' });
      expect(res.status).toBe(400);
    });

    test('E2EE conv: rejects invalid envelope_type', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      const conv = await openE2eeDirect(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'legacy_plaintext',
        });
      expect(res.status).toBe(400);
    });

    test('Legacy conv: rejects ciphertext', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      const legacyRes = await request(app)
        .post('/v1/conversations')
        .set('Authorization', `Bearer ${alice.token}`)
        .send({ user_id: bob.user.id });
      const conv = legacyRes.body.conversation;
      expect(conv.is_e2ee).toBe(false);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_1to1',
        });
      expect(res.status).toBe(400);
      expect(res.body.error).toMatch(/legacy/i);
    });

    test('Legacy conv: plaintext path still works (body-only send)', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      const legacyRes = await request(app)
        .post('/v1/conversations')
        .set('Authorization', `Bearer ${alice.token}`)
        .send({ user_id: bob.user.id });
      const conv = legacyRes.body.conversation;

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({ body: 'hello plaintext' });
      expect(res.status).toBe(201);
      expect(res.body.message.body).toBe('hello plaintext');
      expect(res.body.message.envelope_type).toBe('legacy_plaintext');
      expect(res.body.message.ciphertext).toBeNull();
    });
  });

  describe('GET /v1/conversations/:id/messages', () => {
    test('returns ciphertext as base64 for E2EE messages', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );
      const conv = await openE2eeDirect(
        { token: alice.token, id: alice.user.id },
        { token: bob.token, id: bob.user.id },
      );

      const sentCiphertext = rb64(128);
      await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: sentCiphertext,
          envelope_type: 'signal_1to1',
        });

      const res = await request(app)
        .get(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${bob.token}`);
      expect(res.status).toBe(200);
      expect(res.body.messages.length).toBe(1);
      expect(res.body.messages[0].ciphertext).toBe(sentCiphertext);
      expect(res.body.messages[0].envelope_type).toBe('signal_1to1');
      expect(res.body.messages[0].body).toBeNull();
    });
  });

  // Phase 1f (group E2EE via Sender Keys) acceptance + routing.
  describe('signal_skdm control messages', () => {
    async function openE2eeGroup(
      owner: any,
      otherMembers: any[],
      name = 'Test group',
    ) {
      for (const m of otherMembers) {
        await followBoth(
          { token: owner.token, id: owner.user.id },
          { token: m.token, id: m.user.id },
        );
      }
      const res = await request(app)
        .post('/v1/conversations')
        .set('Authorization', `Bearer ${owner.token}`)
        .send({
          name,
          member_ids: otherMembers.map((m) => m.user.id),
          is_e2ee: true,
        });
      return res.body.conversation;
    }

    test('accepts signal_skdm with recipient_id, stores row with it set', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob]);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(96),
          envelope_type: 'signal_skdm',
          protocol_version: 3,
          recipient_id: bob.user.id,
        });
      expect(res.status).toBe(201);
      expect(res.body.message.envelope_type).toBe('signal_skdm');
      expect(res.body.message.recipient_id).toBe(bob.user.id);
    });

    test('rejects signal_skdm without recipient_id', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob]);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_skdm',
        });
      expect(res.status).toBe(400);
      expect(res.body.error).toMatch(/recipient_id/i);
    });

    test('rejects signal_skdm when recipient is the sender', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob]);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_skdm',
          recipient_id: alice.user.id,
        });
      expect(res.status).toBe(400);
      expect(res.body.error).toMatch(/recipient_id/i);
    });

    test('rejects signal_skdm when recipient is not a group member', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const carol = await createTestUser(); // not in the group
      const conv = await openE2eeGroup(alice, [bob]);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_skdm',
          recipient_id: carol.user.id,
        });
      expect(res.status).toBe(400);
      expect(res.body.error).toMatch(/member/i);
    });

    test('rejects recipient_id on non-SKDM envelope_type', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob]);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_group',
          recipient_id: bob.user.id,
        });
      expect(res.status).toBe(400);
    });

    test('SKDM rows are visible only to the targeted recipient', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const carol = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob, carol]);

      // Alice distributes SKDMs — one to bob, one to carol. Each is
      // a separate 1:1-ciphertext blob in real usage; here we just
      // assert routing, so the actual bytes don't matter.
      await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_skdm',
          recipient_id: bob.user.id,
        });
      await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_skdm',
          recipient_id: carol.user.id,
        });

      const bobRes = await request(app)
        .get(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${bob.token}`);
      const bobSkdms = bobRes.body.messages.filter(
        (m: any) => m.envelope_type === 'signal_skdm',
      );
      expect(bobSkdms.length).toBe(1);
      expect(bobSkdms[0].recipient_id).toBe(bob.user.id);

      const carolRes = await request(app)
        .get(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${carol.token}`);
      const carolSkdms = carolRes.body.messages.filter(
        (m: any) => m.envelope_type === 'signal_skdm',
      );
      expect(carolSkdms.length).toBe(1);
      expect(carolSkdms[0].recipient_id).toBe(carol.user.id);
    });

    test('SKDM rows do NOT bump last_message_at or conversation ordering', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob]);

      const before = await query(
        'SELECT last_message_at FROM conversations WHERE id = $1',
        [conv.id],
      );
      expect(before.rows[0].last_message_at).toBeNull();

      await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_skdm',
          recipient_id: bob.user.id,
        });

      const after = await query(
        'SELECT last_message_at FROM conversations WHERE id = $1',
        [conv.id],
      );
      // SKDMs are control messages — shouldn't surface as "newest
      // message" in the conversations list.
      expect(after.rows[0].last_message_at).toBeNull();
    });

    test('GET /v1/conversations unread_count excludes signal_skdm', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob]);

      // One visible group message + one SKDM addressed at bob.
      // Bob's unread count should be 1 (the group message), not 2.
      await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_skdm',
          recipient_id: bob.user.id,
        });
      await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_group',
          conversation_epoch: conv.epoch,
        });

      const list = await request(app)
        .get('/v1/conversations')
        .set('Authorization', `Bearer ${bob.token}`);
      expect(list.status).toBe(200);
      const row = list.body.conversations.find((c: any) => c.id === conv.id);
      expect(row).toBeDefined();
      expect(Number(row.unread_count)).toBe(1);
    });

    test('rejects signal_group with stale conversation_epoch', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob]);

      await query('UPDATE conversations SET epoch = epoch + 1 WHERE id = $1', [
        conv.id,
      ]);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/messages`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({
          ciphertext: rb64(64),
          envelope_type: 'signal_group',
          conversation_epoch: conv.epoch,
        });
      expect(res.status).toBe(409);
      expect(res.body.error).toMatch(/stale conversation epoch/i);
    });
  });

  describe('group epoch bumps on membership change', () => {
    async function openE2eeGroup(
      owner: any,
      otherMembers: any[],
      name = 'Epoch test',
    ) {
      for (const m of otherMembers) {
        await followBoth(
          { token: owner.token, id: owner.user.id },
          { token: m.token, id: m.user.id },
        );
      }
      const res = await request(app)
        .post('/v1/conversations')
        .set('Authorization', `Bearer ${owner.token}`)
        .send({
          name,
          member_ids: otherMembers.map((m) => m.user.id),
          is_e2ee: true,
        });
      return res.body.conversation;
    }

    async function readEpoch(convId: string) {
      const { rows } = await query(
        'SELECT epoch FROM conversations WHERE id = $1',
        [convId],
      );
      return rows[0].epoch;
    }

    test('POST /:id/members bumps epoch and stamps new member joined_at_epoch', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const carol = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob]);
      // Alice has to mutual-follow carol before she can be added.
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: carol.token, id: carol.user.id },
      );

      expect(await readEpoch(conv.id)).toBe(0);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/members`)
        .set('Authorization', `Bearer ${alice.token}`)
        .send({ user_ids: [carol.user.id] });
      expect(res.status).toBe(200);
      expect(res.body.conversation.epoch).toBe(1);
      expect(await readEpoch(conv.id)).toBe(1);

      const { rows } = await query(
        'SELECT joined_at_epoch FROM conversation_members WHERE conversation_id = $1 AND user_id = $2',
        [conv.id, carol.user.id],
      );
      expect(rows[0].joined_at_epoch).toBe(1);
    });

    test('DELETE /:id/members/:userId bumps epoch', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const carol = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: carol.token, id: carol.user.id },
      );
      const conv = await openE2eeGroup(alice, [bob, carol]);
      expect(await readEpoch(conv.id)).toBe(0);

      const res = await request(app)
        .delete(`/v1/conversations/${conv.id}/members/${carol.user.id}`)
        .set('Authorization', `Bearer ${alice.token}`);
      expect(res.status).toBe(200);
      expect(await readEpoch(conv.id)).toBe(1);
    });

    test('POST /:id/leave bumps epoch when group remains', async () => {
      const alice = await createTestUser();
      const bob = await createTestUser();
      const carol = await createTestUser();
      await followBoth(
        { token: alice.token, id: alice.user.id },
        { token: carol.token, id: carol.user.id },
      );
      const conv = await openE2eeGroup(alice, [bob, carol]);
      expect(await readEpoch(conv.id)).toBe(0);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/leave`)
        .set('Authorization', `Bearer ${bob.token}`);
      expect(res.status).toBe(200);
      expect(res.body.dissolved).toBe(false);
      expect(await readEpoch(conv.id)).toBe(1);
    });

    test('POST /:id/leave on the last member dissolves without epoch bump', async () => {
      // When the creator leaves as the last member, the conversation
      // is hard-deleted. Epoch is moot — we just assert the dissolve
      // path doesn't throw on the (now-missing) row.
      const alice = await createTestUser();
      const bob = await createTestUser();
      const conv = await openE2eeGroup(alice, [bob]);

      // Bob leaves first so alice becomes the last.
      await request(app)
        .post(`/v1/conversations/${conv.id}/leave`)
        .set('Authorization', `Bearer ${bob.token}`);

      const res = await request(app)
        .post(`/v1/conversations/${conv.id}/leave`)
        .set('Authorization', `Bearer ${alice.token}`);
      expect(res.status).toBe(200);
      expect(res.body.dissolved).toBe(true);
      const { rows } = await query(
        'SELECT id FROM conversations WHERE id = $1',
        [conv.id],
      );
      expect(rows.length).toBe(0);
    });
  });
});

// ==================== E2EE DM ATTACHMENTS (Phase 1g) ====================

describe('E2EE DM attachments', () => {
  test('POST /v1/dm-attachments/upload-url returns presigned PUT + dm/ key', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/dm-attachments/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({ content_type: 'image/jpeg' });
    expect(res.status).toBe(200);
    expect(res.body.key).toMatch(/^dm\//);
    expect(typeof res.body.upload_url).toBe('string');
    expect(res.body.upload_url.length).toBeGreaterThan(50);
  });

  test('POST /v1/dm-attachments/upload-url rejects missing content_type', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/dm-attachments/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({});
    expect(res.status).toBe(400);
  });

  test('POST /v1/dm-attachments/upload-url rejects non-string content_type', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/dm-attachments/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({ content_type: 42 });
    expect(res.status).toBe(400);
  });

  test('GET /v1/dm-attachments/:id returns presigned download URL', async () => {
    const { token } = await createTestUser();
    // Grab a real id by doing the upload-url dance first — server
    // doesn't store anything about the object itself, just generates
    // presigned URLs against the key.
    const createRes = await request(app)
      .post('/v1/dm-attachments/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({ content_type: 'image/png' });
    const key: string = createRes.body.key;
    // key is "dm/<uuid>"; the route expects the uuid part.
    const id = key.replace(/^dm\//, '');

    const res = await request(app)
      .get(`/v1/dm-attachments/${id}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(typeof res.body.download_url).toBe('string');
    expect(res.body.download_url.length).toBeGreaterThan(50);
  });

  test('GET /v1/dm-attachments/:id rejects malformed ids', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .get('/v1/dm-attachments/not-a-uuid!')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(400);
  });

  test('POST + GET require auth', async () => {
    const post = await request(app).post('/v1/dm-attachments/upload-url');
    expect(post.status).toBe(401);
    const get = await request(app).get(
      '/v1/dm-attachments/00000000-0000-0000-0000-000000000000',
    );
    expect(get.status).toBe(401);
  });
});

// ==================== GROUPS ====================
describe('Groups', () => {
  test('POST /v1/groups creates a group', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'Family', color: '#FF0000' });
    expect(res.status).toBe(201);
    expect(res.body.group.name).toBe('Family');
    expect(res.body.group.color).toBe('#FF0000');
  });

  test('GET /v1/groups lists groups', async () => {
    const { token } = await createTestUser();
    await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'Friends' });

    const res = await request(app)
      .get('/v1/groups')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.groups.length).toBeGreaterThanOrEqual(1);
  });

  test('PATCH /v1/groups/:id updates group', async () => {
    const { token } = await createTestUser();
    const createRes = await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'Old Name' });

    const res = await request(app)
      .patch(`/v1/groups/${createRes.body.group.id}`)
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'New Name' });
    expect(res.status).toBe(200);
    expect(res.body.group.name).toBe('New Name');
  });

  test('Duplicate group name rejected', async () => {
    const { token } = await createTestUser();
    await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'UniqueGroup' });

    const res = await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'UniqueGroup' });
    expect(res.status).toBe(409);
  });

  test('PUT /v1/groups/:id/members sets members', async () => {
    const { user: owner, token: ownerToken } = await createTestUser();
    const { user: friend } = await createTestUser();
    await createMutualFollow(owner.id, friend.id);

    const groupRes = await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ name: 'Test Group' });

    const res = await request(app)
      .put(`/v1/groups/${groupRes.body.group.id}/members`)
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ user_ids: [friend.id] });
    expect(res.status).toBe(200);

    // Verify members
    const membersRes = await request(app)
      .get(`/v1/groups/${groupRes.body.group.id}/members`)
      .set('Authorization', `Bearer ${ownerToken}`);
    expect(membersRes.body.members.length).toBe(1);
    expect(membersRes.body.members[0].id).toBe(friend.id);
  });

  test('Cannot add non-mutual follow to group', async () => {
    const { user: owner, token: ownerToken } = await createTestUser();
    const { user: stranger } = await createTestUser();

    const groupRes = await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ name: 'Restricted' });

    const res = await request(app)
      .put(`/v1/groups/${groupRes.body.group.id}/members`)
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ user_ids: [stranger.id] });
    expect(res.status).toBe(400);
  });

  test('DELETE /v1/groups/:id deletes group', async () => {
    const { token } = await createTestUser();
    const createRes = await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'ToDelete' });

    const res = await request(app)
      .delete(`/v1/groups/${createRes.body.group.id}`)
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);

    // Group should be gone
    const listRes = await request(app)
      .get('/v1/groups')
      .set('Authorization', `Bearer ${token}`);
    const found = listRes.body.groups.find(
      (g: any) => g.id === createRes.body.group.id,
    );
    expect(found).toBeUndefined();
  });

  test('POST /v1/groups enforces max group limit', async () => {
    const { token } = await createTestUser();
    // Create 10 groups (the limit)
    for (let i = 0; i < 10; i++) {
      const res = await request(app)
        .post('/v1/groups')
        .set('Authorization', `Bearer ${token}`)
        .send({ name: `Group ${i}` });
      expect(res.status).toBe(201);
    }
    // 11th should fail
    const res = await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'Group 10' });
    expect(res.status).toBe(400);
    expect(res.body.error).toContain('10');
  });

  test('Feed filtered by group', async () => {
    const { user: owner, token: ownerToken } = await createTestUser();
    const { user: friend, token: friendToken } = await createTestUser();
    const { user: otherFriend, token: otherToken } = await createTestUser();

    await createMutualFollow(owner.id, friend.id);
    await createMutualFollow(owner.id, otherFriend.id);

    // Create group with only friend
    const groupRes = await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ name: 'Selected' });
    const groupId = groupRes.body.group.id;

    await request(app)
      .put(`/v1/groups/${groupId}/members`)
      .set('Authorization', `Bearer ${ownerToken}`)
      .send({ user_ids: [friend.id] });

    // Both friends post
    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${friendToken}`)
      .send({
        caption: 'From friend',
        media: [{ key: 'a.jpg', media_type: 'photo', position: 0 }],
      });

    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${otherToken}`)
      .send({
        caption: 'From other',
        media: [{ key: 'b.jpg', media_type: 'photo', position: 0 }],
      });

    // Feed filtered by group should only show friend's post
    const res = await request(app)
      .get('/v1/feed')
      .query({ group_id: groupId })
      .set('Authorization', `Bearer ${ownerToken}`);
    expect(res.status).toBe(200);
    const userIds = res.body.posts.map((p: any) => p.user_id);
    expect(userIds).toContain(friend.id);
    expect(userIds).not.toContain(otherFriend.id);
  });
});

// ==================== SUBSCRIPTION / FEED HISTORY GATE ====================
describe('Feed history gate', () => {
  test('Expired users cannot see posts older than 30 days', async () => {
    const { user: poster, token: posterToken } = await createTestUser();
    const { user: viewer, token: viewerToken } = await createTestUser({ subscription_status: 'expired' });
    await createMutualFollow(poster.id, viewer.id);

    // Create an old post (35 days ago)
    await query(
      `INSERT INTO posts (user_id, caption, created_at)
       VALUES ($1, 'old post', NOW() - INTERVAL '35 days')`,
      [poster.id],
    );

    // Create a recent post
    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${posterToken}`)
      .send({
        caption: 'recent post',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${viewerToken}`);
    expect(res.status).toBe(200);

    const captions = res.body.posts.map((p: any) => p.caption);
    expect(captions).toContain('recent post');
    expect(captions).not.toContain('old post');
  });

  test('Trial users can see posts older than 30 days', async () => {
    const { user: poster, token: posterToken } = await createTestUser();
    const { user: viewer, token: viewerToken } = await createTestUser({ subscription_status: 'trial' });
    await createMutualFollow(poster.id, viewer.id);

    // Create an old post (35 days ago)
    await query(
      `INSERT INTO posts (user_id, caption, created_at)
       VALUES ($1, 'old trial post', NOW() - INTERVAL '35 days')`,
      [poster.id],
    );

    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${viewerToken}`);
    expect(res.status).toBe(200);

    const captions = res.body.posts.map((p: any) => p.caption);
    expect(captions).toContain('old trial post');
  });

  // Own-profile bypass: a Free user looking at their OWN profile must
  // see everything they posted, regardless of the 30-day history gate.
  // The gate is about what the platform shows you for free from the
  // wider network — it should never hide your own content from you.
  test('Own profile shows full history for Free users (bypasses the 30-day gate)', async () => {
    const { user: me, token: myToken } = await createTestUser({
      subscription_status: 'expired',
    });

    // Old post (35 days ago) via direct insert so created_at is backdated.
    await query(
      `INSERT INTO posts (user_id, caption, created_at)
       VALUES ($1, 'my old post', NOW() - INTERVAL '35 days')`,
      [me.id],
    );
    // Recent post (today) via the API.
    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${myToken}`)
      .send({
        caption: 'my recent post',
        media: [{ key: 'recent.jpg', media_type: 'photo', position: 0 }],
      });

    // Viewing MY own profile — should see both.
    const res = await request(app)
      .get(`/v1/posts/by-user/${me.id}`)
      .set('Authorization', `Bearer ${myToken}`);
    expect(res.status).toBe(200);
    const captions = res.body.posts.map((p: any) => p.caption);
    expect(captions).toContain('my old post');
    expect(captions).toContain('my recent post');
  });

  // The bypass is self-only: a Free user viewing SOMEONE ELSE's
  // profile still gets the 30-day cap. Otherwise the plan gate would
  // be trivial to circumvent.
  test("Other user's profile still honors the 30-day gate for Free users", async () => {
    const { user: me, token: myToken } = await createTestUser({
      subscription_status: 'expired',
    });
    const { user: friend, token: friendToken } = await createTestUser();
    await createMutualFollow(me.id, friend.id);

    await query(
      `INSERT INTO posts (user_id, caption, created_at)
       VALUES ($1, 'friend old post', NOW() - INTERVAL '35 days')`,
      [friend.id],
    );
    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${friendToken}`)
      .send({
        caption: 'friend recent post',
        media: [{ key: 'fr.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .get(`/v1/posts/by-user/${friend.id}`)
      .set('Authorization', `Bearer ${myToken}`);
    expect(res.status).toBe(200);
    const captions = res.body.posts.map((p: any) => p.caption);
    expect(captions).toContain('friend recent post');
    expect(captions).not.toContain('friend old post');
  });

  // Build 32: the feed endpoint returns has_older_posts to tell the
  // mobile client whether a paywall banner should actually render.
  // Previously the banner appeared unconditionally for every Free
  // user at the end of the feed — even brand-new users with nothing
  // past the 30-day cutoff — which read as a nag.
  test('GET /v1/feed returns has_older_posts: true for Free user with gated content', async () => {
    const { user: poster } = await createTestUser();
    const { user: viewer, token: viewerToken } = await createTestUser({
      subscription_status: 'expired',
    });
    await createMutualFollow(poster.id, viewer.id);

    // Backdate a post so it's behind the 30-day gate.
    await query(
      `INSERT INTO posts (user_id, caption, created_at)
       VALUES ($1, 'gated', NOW() - INTERVAL '35 days')`,
      [poster.id],
    );

    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${viewerToken}`);
    expect(res.status).toBe(200);
    expect(res.body.has_older_posts).toBe(true);
  });

  test('GET /v1/feed returns has_older_posts: false when no older content exists', async () => {
    const { user: poster, token: posterToken } = await createTestUser();
    const { user: viewer, token: viewerToken } = await createTestUser({
      subscription_status: 'expired',
    });
    await createMutualFollow(poster.id, viewer.id);

    // Recent post only — nothing past the 30-day cutoff.
    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${posterToken}`)
      .send({
        caption: 'recent',
        media: [{ key: 'img.jpg', media_type: 'photo', position: 0 }],
      });

    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${viewerToken}`);
    expect(res.status).toBe(200);
    expect(res.body.has_older_posts).toBe(false);
  });

  test('GET /v1/feed returns has_older_posts: false for Pro users (no gate)', async () => {
    const { user: poster } = await createTestUser();
    const { user: viewer, token: viewerToken } = await createTestUser({
      subscription_status: 'active',
    });
    await createMutualFollow(poster.id, viewer.id);

    // Even with content behind what would be the gate for Free, Pro
    // users don't hit a cutoff — so the flag is always false for them
    // (no paywall banner to show).
    await query(
      `INSERT INTO posts (user_id, caption, created_at)
       VALUES ($1, 'old', NOW() - INTERVAL '30 days')`,
      [poster.id],
    );

    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${viewerToken}`);
    expect(res.status).toBe(200);
    expect(res.body.has_older_posts).toBe(false);
  });
});

// ==================== API CONTRACT (snake_case) ====================
describe('API contract: all responses use snake_case keys', () => {
  // Helper: recursively check that no key in an object uses camelCase
  function findCamelCaseKeys(obj: any, path = ''): string[] {
    const violations: string[] = [];
    if (obj === null || obj === undefined) return violations;
    if (Array.isArray(obj)) {
      obj.forEach((item, i) => violations.push(...findCamelCaseKeys(item, `${path}[${i}]`)));
      return violations;
    }
    if (typeof obj === 'object') {
      for (const key of Object.keys(obj)) {
        // camelCase = has a lowercase letter followed by an uppercase letter
        if (/[a-z][A-Z]/.test(key)) {
          violations.push(`${path}.${key}`);
        }
        violations.push(...findCamelCaseKeys(obj[key], `${path}.${key}`));
      }
    }
    return violations;
  }

  test('GET /v1/users/me returns snake_case keys', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .get('/v1/users/me')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    const violations = findCamelCaseKeys(res.body);
    expect(violations).toEqual([]);
    // Verify key fields exist
    expect(res.body.user.display_name).toBeDefined();
    expect(res.body.user.email).toBeDefined();
    expect(res.body.user.created_at).toBeDefined();
  });

  test('GET /v1/feed returns snake_case keys', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b, token: tokenB } = await createTestUser();
    await createMutualFollow(a.id, b.id);

    await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ caption: 'contract test', media: [{ key: 'c.jpg', media_type: 'photo', position: 0 }] });

    const res = await request(app)
      .get('/v1/feed')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    const violations = findCamelCaseKeys(res.body);
    expect(violations).toEqual([]);
    expect(res.body.posts[0].user_id).toBeDefined();
    expect(res.body.posts[0].created_at).toBeDefined();
    expect(res.body.posts[0].display_name).toBeDefined();
    expect(res.body.posts[0].avatar_url).toBeDefined();
    expect(res.body.posts[0].media[0].media_url).toBeDefined();
    expect(res.body.posts[0].media[0].media_type).toBeDefined();
  });

  test('POST /v1/posts returns snake_case keys', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/posts')
      .set('Authorization', `Bearer ${token}`)
      .send({ caption: 'contract', media: [{ key: 'x.jpg', media_type: 'photo', position: 0 }] });
    expect(res.status).toBe(201);
    const violations = findCamelCaseKeys(res.body);
    expect(violations).toEqual([]);
    expect(res.body.post.user_id).toBeDefined();
    expect(res.body.post.media[0].media_url).toBeDefined();
    expect(res.body.post.media[0].post_id).toBeDefined();
  });

  test('GET /v1/conversations returns snake_case keys', async () => {
    const { user: a, token: tokenA } = await createTestUser();
    const { user: b, token: tokenB } = await createTestUser();
    await createMutualFollow(a.id, b.id);

    const convRes = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ user_id: b.id });

    // Send a message so the conversation appears in the list
    await request(app)
      .post(`/v1/conversations/${convRes.body.conversation.id}/messages`)
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ body: 'Hello' });

    const res = await request(app)
      .get('/v1/conversations')
      .set('Authorization', `Bearer ${tokenA}`);
    expect(res.status).toBe(200);
    const violations = findCamelCaseKeys(res.body);
    expect(violations).toEqual([]);
    expect(res.body.conversations[0].last_message_at).toBeDefined();
    expect(res.body.conversations[0].unread_count).toBeDefined();
  });

  test('POST /v1/posts/upload-url returns snake_case keys', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/posts/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({ content_type: 'image/jpeg', count: 2 });
    expect(res.status).toBe(200);
    const violations = findCamelCaseKeys(res.body);
    expect(violations).toEqual([]);
    expect(res.body.uploads).toHaveLength(2);
    expect(res.body.uploads[0].upload_url).toBeDefined();
    expect(res.body.uploads[0].key).toBeDefined();
  });

  test('GET /v1/groups returns snake_case keys', async () => {
    const { token } = await createTestUser();
    await request(app)
      .post('/v1/groups')
      .set('Authorization', `Bearer ${token}`)
      .send({ name: 'ContractTest' });

    const res = await request(app)
      .get('/v1/groups')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    const violations = findCamelCaseKeys(res.body);
    expect(violations).toEqual([]);
    expect(res.body.groups[0].created_at).toBeDefined();
    expect(res.body.groups[0].user_id).toBeDefined();
  });
});

// ==================== DEVICES ====================
describe('Devices', () => {
  test('POST /v1/devices/token registers a device token', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/devices/token')
      .set('Authorization', `Bearer ${token}`)
      .send({ token: 'fcm-token-abc123', platform: 'ios' });
    expect(res.status).toBe(200);
    expect(res.body.message).toBe('Token registered');
  });

  test('POST /v1/devices/token rejects missing token', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/devices/token')
      .set('Authorization', `Bearer ${token}`)
      .send({ platform: 'ios' });
    expect(res.status).toBe(400);
  });

  test('POST /v1/devices/token rejects invalid platform', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .post('/v1/devices/token')
      .set('Authorization', `Bearer ${token}`)
      .send({ token: 'fcm-token-abc', platform: 'windows' });
    expect(res.status).toBe(400);
  });

  test('POST /v1/devices/token upserts on same token', async () => {
    const { token: tokenA } = await createTestUser();
    const { token: tokenB } = await createTestUser();
    const deviceToken = `shared-device-${Date.now()}`;

    // Register with user A
    await request(app)
      .post('/v1/devices/token')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ token: deviceToken, platform: 'ios' });

    // Register same device token with user B (e.g. logged out + new login)
    const res = await request(app)
      .post('/v1/devices/token')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ token: deviceToken, platform: 'ios' });
    expect(res.status).toBe(200);

    // Should only have one record for this token
    const { rows } = await query(
      'SELECT * FROM device_tokens WHERE token = $1',
      [deviceToken],
    );
    expect(rows.length).toBe(1);
  });

  test('DELETE /v1/devices/token unregisters a device token', async () => {
    const { token } = await createTestUser();
    const deviceToken = `delete-me-${Date.now()}`;

    await request(app)
      .post('/v1/devices/token')
      .set('Authorization', `Bearer ${token}`)
      .send({ token: deviceToken, platform: 'android' });

    const res = await request(app)
      .delete('/v1/devices/token')
      .set('Authorization', `Bearer ${token}`)
      .send({ token: deviceToken });
    expect(res.status).toBe(200);
    expect(res.body.message).toBe('Token unregistered');

    // Verify it's gone
    const { rows } = await query(
      'SELECT * FROM device_tokens WHERE token = $1',
      [deviceToken],
    );
    expect(rows.length).toBe(0);
  });

  test('DELETE /v1/devices/token rejects missing token', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .delete('/v1/devices/token')
      .set('Authorization', `Bearer ${token}`)
      .send({});
    expect(res.status).toBe(400);
  });
});

// ==================== E2EE KEY REGISTRY (Phase 1c) ====================

describe('E2EE key registry', () => {
  // Helpers: random bytes of exact length, base64-encoded. The server
  // doesn't verify the crypto — it just stores bytes — so the tests
  // can use random garbage of the right shape.
  function rb64(n: number): string {
    return crypto.randomBytes(n).toString('base64');
  }
  // Kyber1024 public key is ~1568 bytes; pick a value inside the
  // server's accepted range (1500–1700) so tests don't depend on
  // the precise encoding length.
  const KYBER_PUB_BYTES = 1568;
  function makeBundle(
    otpkCount = 5,
    startId = 1,
    kyberCount = 3,
    kyberStartId = 1,
  ) {
    return {
      identity_key_pub: rb64(33),
      signed_prekey: {
        id: 1,
        public: rb64(33),
        signature: rb64(64),
      },
      one_time_prekeys: Array.from({ length: otpkCount }, (_, i) => ({
        id: startId + i,
        public: rb64(33),
      })),
      kyber_prekeys: Array.from({ length: kyberCount }, (_, i) => ({
        id: kyberStartId + i,
        public: rb64(KYBER_PUB_BYTES),
        signature: rb64(64),
      })),
    };
  }

  describe('POST /v1/devices/keys/upload', () => {
    test('stores identity, signed prekey, OTPKs, and Kyber prekeys', async () => {
      const { token, user } = await createTestUser();
      const bundle = makeBundle(3, 1, 2, 1);
      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(bundle);
      expect(res.status).toBe(200);
      expect(res.body.one_time_prekey_count).toBe(3);
      expect(res.body.kyber_prekey_count).toBe(2);

      const dk = await query(
        'SELECT * FROM device_keys WHERE user_id = $1',
        [user.id],
      );
      expect(dk.rows.length).toBe(1);
      expect(dk.rows[0].identity_key_pub.length).toBe(33);
      expect(dk.rows[0].signed_prekey_sig.length).toBe(64);
      expect(dk.rows[0].revoked_at).toBeNull();

      const otpks = await query(
        'SELECT * FROM one_time_prekeys WHERE user_id = $1 ORDER BY key_id',
        [user.id],
      );
      expect(otpks.rows.length).toBe(3);
      expect(otpks.rows[0].key_id).toBe(1);

      const kpks = await query(
        'SELECT * FROM kyber_prekeys WHERE user_id = $1 ORDER BY key_id',
        [user.id],
      );
      expect(kpks.rows.length).toBe(2);
      expect(kpks.rows[0].key_id).toBe(1);
      expect(kpks.rows[0].key_pub.length).toBe(KYBER_PUB_BYTES);
      expect(kpks.rows[0].signature.length).toBe(64);
    });

    test('rejects missing kyber_prekeys with 400', async () => {
      const { token } = await createTestUser();
      const bundle: any = makeBundle(2);
      delete bundle.kyber_prekeys;
      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(bundle);
      expect(res.status).toBe(400);
      expect(res.body.error).toMatch(/kyber_prekeys/);
    });

    test('rejects empty kyber_prekeys array with 400', async () => {
      const { token } = await createTestUser();
      const bundle = makeBundle(2);
      bundle.kyber_prekeys = [];
      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(bundle);
      expect(res.status).toBe(400);
    });

    test('rejects kyber public key of wrong size', async () => {
      const { token } = await createTestUser();
      const bundle = makeBundle(2);
      bundle.kyber_prekeys[0].public = rb64(33); // too small
      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(bundle);
      expect(res.status).toBe(400);
    });

    test('rejects duplicate active key set with 409', async () => {
      const { token } = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(2));

      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(2));
      expect(res.status).toBe(409);
    });

    test('rejects identity_key_pub of wrong byte length', async () => {
      const { token } = await createTestUser();
      const bundle = makeBundle(1);
      bundle.identity_key_pub = rb64(32); // should be 33
      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(bundle);
      expect(res.status).toBe(400);
      expect(res.body.error).toMatch(/33 bytes/);
    });

    test('rejects signature of wrong byte length', async () => {
      const { token } = await createTestUser();
      const bundle = makeBundle(1);
      bundle.signed_prekey.signature = rb64(32); // should be 64
      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(bundle);
      expect(res.status).toBe(400);
    });

    test('rejects OTPK batch > 200', async () => {
      const { token } = await createTestUser();
      const bundle = makeBundle(201);
      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(bundle);
      expect(res.status).toBe(400);
    });

    test('rejects non-positive key ids', async () => {
      const { token } = await createTestUser();
      const bundle = makeBundle(1);
      bundle.signed_prekey.id = 0;
      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(bundle);
      expect(res.status).toBe(400);
    });
  });

  describe('POST /v1/devices/keys/replenish', () => {
    test('adds new OTPKs past the existing max id', async () => {
      const { token, user } = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(5));

      const replenishBody = {
        one_time_prekeys: Array.from({ length: 10 }, (_, i) => ({
          id: 100 + i,
          public: rb64(33),
        })),
      };
      const res = await request(app)
        .post('/v1/devices/keys/replenish')
        .set('Authorization', `Bearer ${token}`)
        .send(replenishBody);
      expect(res.status).toBe(200);
      expect(res.body.one_time_prekeys_added).toBe(10);

      const otpks = await query(
        'SELECT key_id FROM one_time_prekeys WHERE user_id = $1 ORDER BY key_id',
        [user.id],
      );
      expect(otpks.rows.length).toBe(15); // 5 original + 10 new
      expect(otpks.rows.map((r: any) => r.key_id)).toContain(100);
    });

    test('ignores duplicate key_ids via ON CONFLICT', async () => {
      const { token, user } = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(2));

      // Submit the same key_id 1 that's already stored — should be ignored.
      const res = await request(app)
        .post('/v1/devices/keys/replenish')
        .set('Authorization', `Bearer ${token}`)
        .send({
          one_time_prekeys: [
            { id: 1, public: rb64(33) },
            { id: 50, public: rb64(33) },
          ],
        });
      expect(res.status).toBe(200);

      const otpks = await query(
        'SELECT * FROM one_time_prekeys WHERE user_id = $1',
        [user.id],
      );
      expect(otpks.rows.length).toBe(3); // 2 original + 1 new (id 50); id 1 collision ignored
    });

    test('404 when no active key set exists', async () => {
      const { token } = await createTestUser();
      const res = await request(app)
        .post('/v1/devices/keys/replenish')
        .set('Authorization', `Bearer ${token}`)
        .send({
          one_time_prekeys: [{ id: 1, public: rb64(33) }],
        });
      expect(res.status).toBe(404);
    });
  });

  describe('POST /v1/devices/keys/rotate-signed', () => {
    test('replaces the signed prekey and sets rotated_at', async () => {
      const { token, user } = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(2));

      const newSpk = { id: 2, public: rb64(33), signature: rb64(64) };
      const res = await request(app)
        .post('/v1/devices/keys/rotate-signed')
        .set('Authorization', `Bearer ${token}`)
        .send({ signed_prekey: newSpk });
      expect(res.status).toBe(200);
      expect(res.body.id).toBe(2);

      const dk = await query(
        'SELECT signed_prekey_id, rotated_at FROM device_keys WHERE user_id = $1',
        [user.id],
      );
      expect(dk.rows[0].signed_prekey_id).toBe(2);
      expect(dk.rows[0].rotated_at).not.toBeNull();
    });

    test('404 when no active key set exists', async () => {
      const { token } = await createTestUser();
      const res = await request(app)
        .post('/v1/devices/keys/rotate-signed')
        .set('Authorization', `Bearer ${token}`)
        .send({ signed_prekey: { id: 1, public: rb64(33), signature: rb64(64) } });
      expect(res.status).toBe(404);
    });
  });

  describe('POST /v1/devices/revoke', () => {
    test('marks the active key set revoked', async () => {
      const { token, user } = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(2));

      const res = await request(app)
        .post('/v1/devices/revoke')
        .set('Authorization', `Bearer ${token}`)
        .send({});
      expect(res.status).toBe(200);

      const dk = await query(
        'SELECT revoked_at FROM device_keys WHERE user_id = $1',
        [user.id],
      );
      expect(dk.rows[0].revoked_at).not.toBeNull();
    });

    test('is idempotent when no active keys', async () => {
      const { token } = await createTestUser();
      const res = await request(app)
        .post('/v1/devices/revoke')
        .set('Authorization', `Bearer ${token}`)
        .send({});
      expect(res.status).toBe(200); // success-as-no-op
    });

    test('re-upload works after revoke', async () => {
      const { token, user } = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(2));
      await request(app)
        .post('/v1/devices/revoke')
        .set('Authorization', `Bearer ${token}`)
        .send({});
      const res = await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(3));
      expect(res.status).toBe(200);

      // Two rows in history: one revoked, one active.
      const rows = await query(
        'SELECT revoked_at FROM device_keys WHERE user_id = $1 ORDER BY created_at',
        [user.id],
      );
      expect(rows.rows.length).toBe(2);
      expect(rows.rows[0].revoked_at).not.toBeNull();
      expect(rows.rows[1].revoked_at).toBeNull();
    });
  });

  describe('GET /v1/users/:id/keybundle', () => {
    test('returns target user bundle and consumes one OTPK + one Kyber', async () => {
      const owner = await createTestUser();
      const caller = await createTestUser();
      await createMutualFollow(owner.user.id, caller.user.id);
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${owner.token}`)
        .send(makeBundle(3, 1, 3, 1));

      const res = await request(app)
        .get(`/v1/users/${owner.user.id}/keybundle`)
        .set('Authorization', `Bearer ${caller.token}`);
      expect(res.status).toBe(200);

      // Identity + signed prekey shapes
      expect(Buffer.from(res.body.identity_key_pub, 'base64').length).toBe(33);
      expect(res.body.signed_prekey.id).toBe(1);
      expect(
        Buffer.from(res.body.signed_prekey.public, 'base64').length,
      ).toBe(33);
      expect(
        Buffer.from(res.body.signed_prekey.signature, 'base64').length,
      ).toBe(64);

      // One OTPK returned, marked consumed in DB
      expect(res.body.one_time_prekey).not.toBeNull();
      expect(res.body.one_time_prekey.id).toBe(1); // lowest id picked first

      // One Kyber prekey returned, marked consumed
      expect(res.body.kyber_prekey).toBeTruthy();
      expect(res.body.kyber_prekey.id).toBe(1);
      expect(
        Buffer.from(res.body.kyber_prekey.public, 'base64').length,
      ).toBe(KYBER_PUB_BYTES);
      expect(
        Buffer.from(res.body.kyber_prekey.signature, 'base64').length,
      ).toBe(64);

      const consumedOtpk = await query(
        `SELECT consumed_at FROM one_time_prekeys
         WHERE user_id = $1 AND key_id = 1`,
        [owner.user.id],
      );
      expect(consumedOtpk.rows[0].consumed_at).not.toBeNull();

      const consumedKpk = await query(
        `SELECT consumed_at FROM kyber_prekeys
         WHERE user_id = $1 AND key_id = 1`,
        [owner.user.id],
      );
      expect(consumedKpk.rows[0].consumed_at).not.toBeNull();

      // Both pools down by one
      const unconsumed = await query(
        `SELECT
           (SELECT COUNT(*) FROM one_time_prekeys
              WHERE user_id = $1 AND consumed_at IS NULL) AS otpk,
           (SELECT COUNT(*) FROM kyber_prekeys
              WHERE user_id = $1 AND consumed_at IS NULL) AS kpk`,
        [owner.user.id],
      );
      expect(Number(unconsumed.rows[0].otpk)).toBe(2);
      expect(Number(unconsumed.rows[0].kpk)).toBe(2);
    });

    test('returns null one_time_prekey when only OTPK pool is empty', async () => {
      const owner = await createTestUser();
      const caller = await createTestUser();
      await createMutualFollow(owner.user.id, caller.user.id);
      // 1 OTPK + 3 Kyber so we can exhaust OTPKs while keeping Kyber.
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${owner.token}`)
        .send(makeBundle(1, 1, 3, 1));

      // First call consumes the only OTPK (and one Kyber).
      await request(app)
        .get(`/v1/users/${owner.user.id}/keybundle`)
        .set('Authorization', `Bearer ${caller.token}`);

      // Second call: OTPK pool empty, Kyber still has 2.
      const res = await request(app)
        .get(`/v1/users/${owner.user.id}/keybundle`)
        .set('Authorization', `Bearer ${caller.token}`);
      expect(res.status).toBe(200);
      expect(res.body.one_time_prekey).toBeNull();
      expect(res.body.kyber_prekey).toBeTruthy(); // Kyber still flows
      expect(res.body.identity_key_pub).toBeTruthy();
    });

    test('503 when Kyber pool is empty (PQC session setup blocked)', async () => {
      const owner = await createTestUser();
      const caller = await createTestUser();
      await createMutualFollow(owner.user.id, caller.user.id);
      // 5 OTPKs + 1 Kyber so Kyber exhausts first.
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${owner.token}`)
        .send(makeBundle(5, 1, 1, 1));

      // First call consumes the sole Kyber.
      await request(app)
        .get(`/v1/users/${owner.user.id}/keybundle`)
        .set('Authorization', `Bearer ${caller.token}`);

      // Second call: Kyber empty → 503 + OTPK NOT consumed (rollback).
      const res = await request(app)
        .get(`/v1/users/${owner.user.id}/keybundle`)
        .set('Authorization', `Bearer ${caller.token}`);
      expect(res.status).toBe(503);

      // The attempted OTPK consumption should have rolled back.
      const unconsumedOtpk = await query(
        `SELECT COUNT(*) FROM one_time_prekeys
         WHERE user_id = $1 AND consumed_at IS NULL`,
        [owner.user.id],
      );
      // 5 initial, 1 consumed on the first successful fetch, 0 on
      // this failed one = 4 remaining.
      expect(Number(unconsumedOtpk.rows[0].count)).toBe(4);
    });

    test('404 when target user has no active key set', async () => {
      const owner = await createTestUser(); // never uploads
      const caller = await createTestUser();
      await createMutualFollow(owner.user.id, caller.user.id);
      const res = await request(app)
        .get(`/v1/users/${owner.user.id}/keybundle`)
        .set('Authorization', `Bearer ${caller.token}`);
      expect(res.status).toBe(404);
    });

    test('404 after owner revokes keys', async () => {
      const owner = await createTestUser();
      const caller = await createTestUser();
      await createMutualFollow(owner.user.id, caller.user.id);
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${owner.token}`)
        .send(makeBundle(2));
      await request(app)
        .post('/v1/devices/revoke')
        .set('Authorization', `Bearer ${owner.token}`)
        .send({});

      const res = await request(app)
        .get(`/v1/users/${owner.user.id}/keybundle`)
        .set('Authorization', `Bearer ${caller.token}`);
      expect(res.status).toBe(404);
    });

    test('concurrent fetchers each get a distinct OTPK and Kyber prekey', async () => {
      const owner = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${owner.token}`)
        .send(makeBundle(10, 1, 10, 1));

      // Three concurrent callers.
      const callers = await Promise.all([
        createTestUser(),
        createTestUser(),
        createTestUser(),
      ]);
      await Promise.all(
        callers.map((c) => createMutualFollow(owner.user.id, c.user.id)),
      );
      const results = await Promise.all(
        callers.map((c) =>
          request(app)
            .get(`/v1/users/${owner.user.id}/keybundle`)
            .set('Authorization', `Bearer ${c.token}`),
        ),
      );

      const otpkIds = results.map((r) => r.body.one_time_prekey?.id);
      expect(otpkIds.every((id) => typeof id === 'number')).toBe(true);
      expect(new Set(otpkIds).size).toBe(otpkIds.length);

      const kpkIds = results.map((r) => r.body.kyber_prekey?.id);
      expect(kpkIds.every((id) => typeof id === 'number')).toBe(true);
      expect(new Set(kpkIds).size).toBe(kpkIds.length);
    });

    test('403 for unrelated caller and does not consume prekeys', async () => {
      const owner = await createTestUser();
      const caller = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${owner.token}`)
        .send(makeBundle(3, 1, 3, 1));

      const res = await request(app)
        .get(`/v1/users/${owner.user.id}/keybundle`)
        .set('Authorization', `Bearer ${caller.token}`);
      expect(res.status).toBe(403);

      const unconsumed = await query(
        `SELECT
           (SELECT COUNT(*) FROM one_time_prekeys
              WHERE user_id = $1 AND consumed_at IS NULL) AS otpk,
           (SELECT COUNT(*) FROM kyber_prekeys
              WHERE user_id = $1 AND consumed_at IS NULL) AS kpk`,
        [owner.user.id],
      );
      expect(Number(unconsumed.rows[0].otpk)).toBe(3);
      expect(Number(unconsumed.rows[0].kpk)).toBe(3);
    });
  });

  describe('Kyber replenish + revoke cleanup', () => {
    test('replenish can add Kyber prekeys alongside OTPKs', async () => {
      const { token, user } = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(2, 1, 2, 1));

      const res = await request(app)
        .post('/v1/devices/keys/replenish')
        .set('Authorization', `Bearer ${token}`)
        .send({
          one_time_prekeys: Array.from({ length: 3 }, (_, i) => ({
            id: 100 + i,
            public: rb64(33),
          })),
          kyber_prekeys: Array.from({ length: 2 }, (_, i) => ({
            id: 50 + i,
            public: rb64(KYBER_PUB_BYTES),
            signature: rb64(64),
          })),
        });
      expect(res.status).toBe(200);
      expect(res.body.one_time_prekeys_added).toBe(3);
      expect(res.body.kyber_prekeys_added).toBe(2);

      const kpks = await query(
        'SELECT COUNT(*) FROM kyber_prekeys WHERE user_id = $1',
        [user.id],
      );
      expect(Number(kpks.rows[0].count)).toBe(4); // 2 original + 2 new
    });

    test('replenish Kyber alone (no OTPKs) works', async () => {
      const { token } = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(2, 1, 2, 1));

      const res = await request(app)
        .post('/v1/devices/keys/replenish')
        .set('Authorization', `Bearer ${token}`)
        .send({
          kyber_prekeys: [
            { id: 99, public: rb64(KYBER_PUB_BYTES), signature: rb64(64) },
          ],
        });
      expect(res.status).toBe(200);
      expect(res.body.kyber_prekeys_added).toBe(1);
      expect(res.body.one_time_prekeys_added).toBe(0);
    });

    test('revoke deletes Kyber prekeys too', async () => {
      const { token, user } = await createTestUser();
      await request(app)
        .post('/v1/devices/keys/upload')
        .set('Authorization', `Bearer ${token}`)
        .send(makeBundle(2, 1, 2, 1));
      await request(app)
        .post('/v1/devices/revoke')
        .set('Authorization', `Bearer ${token}`)
        .send({});

      const kpks = await query(
        'SELECT COUNT(*) FROM kyber_prekeys WHERE user_id = $1',
        [user.id],
      );
      expect(Number(kpks.rows[0].count)).toBe(0);
    });
  });
});

// ==================== CONTACTS SYNC ====================
describe('Contacts', () => {
  let userC: any, tokenC: string;
  let userD: any, tokenD: string;

  beforeAll(async () => {
    ({ user: userC, token: tokenC } = await createTestUser({
      phone_e164: '+12125559801',
    }));
    // Set phone_hash for userC so it can be matched
    const crypto = require('crypto');
    const hashC = crypto.createHash('sha256').update('+12125559801').digest('hex');
    await query('UPDATE users SET phone_hash = $1 WHERE id = $2', [hashC, userC.id]);

    ({ user: userD, token: tokenD } = await createTestUser({
      phone_e164: '+12125559802',
    }));
    const hashD = crypto.createHash('sha256').update('+12125559802').digest('hex');
    await query('UPDATE users SET phone_hash = $1 WHERE id = $2', [hashD, userD.id]);
  });

  test('POST /v1/contacts/sync returns matched users', async () => {
    const crypto = require('crypto');
    const hashOfD = crypto.createHash('sha256').update('+12125559802').digest('hex');
    const hashOfUnknown = crypto.createHash('sha256').update('+19999999999').digest('hex');

    const res = await request(app)
      .post('/v1/contacts/sync')
      .set('Authorization', `Bearer ${tokenC}`)
      .send({ hashes: [hashOfD, hashOfUnknown] });

    expect(res.status).toBe(200);
    expect(res.body.matches).toBeDefined();
    expect(Array.isArray(res.body.matches)).toBe(true);
    // Should match userD but not the unknown number
    const matchIds = res.body.matches.map((m: any) => m.id);
    expect(matchIds).toContain(userD.id);
    expect(matchIds).not.toContain(userC.id); // should not match self
  });

  test('POST /v1/contacts/sync rejects empty hashes', async () => {
    const res = await request(app)
      .post('/v1/contacts/sync')
      .set('Authorization', `Bearer ${tokenC}`)
      .send({ hashes: [] });

    expect(res.status).toBe(400);
  });

  test('GET /v1/contacts/matches returns cached results', async () => {
    const res = await request(app)
      .get('/v1/contacts/matches')
      .set('Authorization', `Bearer ${tokenC}`);

    expect(res.status).toBe(200);
    expect(res.body.matches).toBeDefined();
  });

  test('POST /v1/contacts/sync requires auth', async () => {
    const res = await request(app)
      .post('/v1/contacts/sync')
      .send({ hashes: ['abc123'] });

    expect(res.status).toBe(401);
  });

  test('POST /v1/contacts/sync NEVER creates follows, even when both users have each other', async () => {
    // Regression guard: an earlier version of this route auto-mutually-
    // followed two users when both had each other's hash in their
    // contact upload. That surprised users (suddenly following someone
    // they didn't pick) and made the App Review disclosure copy harder
    // to keep accurate. Removed in build 37 — this test pins the
    // current behavior so it doesn't sneak back in.
    const crypto = require('crypto');
    const { user: alice, token: aliceTok } = await createTestUser({
      phone_e164: '+12125559900',
    });
    const aliceHash = crypto
      .createHash('sha256')
      .update('+12125559900')
      .digest('hex');
    await query('UPDATE users SET phone_hash = $1 WHERE id = $2', [
      aliceHash,
      alice.id,
    ]);

    const { user: bob, token: bobTok } = await createTestUser({
      phone_e164: '+12125559901',
    });
    const bobHash = crypto
      .createHash('sha256')
      .update('+12125559901')
      .digest('hex');
    await query('UPDATE users SET phone_hash = $1 WHERE id = $2', [
      bobHash,
      bob.id,
    ]);

    // Alice syncs with Bob's hash.
    const aliceRes = await request(app)
      .post('/v1/contacts/sync')
      .set('Authorization', `Bearer ${aliceTok}`)
      .send({ hashes: [bobHash] });
    expect(aliceRes.status).toBe(200);
    expect(
      aliceRes.body.matches.find((m: any) => m.id === bob.id)?.is_mutual,
    ).toBe(false);

    // Bob syncs with Alice's hash. The old auto-follow path would have
    // created a mutual follow here; the new behavior must not.
    const bobRes = await request(app)
      .post('/v1/contacts/sync')
      .set('Authorization', `Bearer ${bobTok}`)
      .send({ hashes: [aliceHash] });
    expect(bobRes.status).toBe(200);
    expect(
      bobRes.body.matches.find((m: any) => m.id === alice.id)?.is_mutual,
    ).toBe(false);

    // Confirm the follows table stayed empty for this pair.
    const { rows: follows } = await query(
      `SELECT * FROM follows
       WHERE (follower_id = $1 AND followee_id = $2)
          OR (follower_id = $2 AND followee_id = $1)`,
      [alice.id, bob.id],
    );
    expect(follows.length).toBe(0);

    // And no new_mutual notifications were generated.
    const { rows: notifs } = await query(
      `SELECT * FROM notifications
       WHERE type = 'new_mutual'
         AND ((user_id = $1 AND actor_id = $2)
           OR (user_id = $2 AND actor_id = $1))`,
      [alice.id, bob.id],
    );
    expect(notifs.length).toBe(0);
  });
});

// ==================== NOTIFICATION PREFERENCES ====================
describe('Badge count + feed-seen (build 38)', () => {
  // Sanity: feed-seen returns 200 + bumps the timestamp.
  test('POST /v1/users/me/feed-seen sets last_feed_seen_at', async () => {
    const { user, token } = await createTestUser();
    await query('UPDATE users SET last_feed_seen_at = NULL WHERE id = $1', [
      user.id,
    ]);

    const res = await request(app)
      .post('/v1/users/me/feed-seen')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);

    const { rows } = await query(
      'SELECT last_feed_seen_at FROM users WHERE id = $1',
      [user.id],
    );
    expect(rows[0].last_feed_seen_at).not.toBeNull();
  });

  // The badge function isn't exported through HTTP; we exercise it
  // via the firebase module directly. This validates the SQL math
  // (post counts + DM counts, signal_skdm exclusion) without
  // depending on a push-fanout integration test.
  test('getUserBadgeCount: counts unread posts from mutual follows since last_feed_seen_at', async () => {
    const { getUserBadgeCount } = require('../src/firebase');
    const { user: alice, token: aliceTok } = await createTestUser();
    const { user: bob } = await createTestUser();
    await followBoth(
      { token: aliceTok, id: alice.id },
      { token: (await loginAs(bob)).token, id: bob.id },
    );

    // Mark alice's feed as seen NOW so any post by bob from this
    // moment forward counts as new.
    await request(app)
      .post('/v1/users/me/feed-seen')
      .set('Authorization', `Bearer ${aliceTok}`);

    // No new posts → 0.
    expect(await getUserBadgeCount(alice.id)).toBe(0);

    // Bob posts twice. Both should land in alice's badge.
    await query(
      `INSERT INTO posts (user_id, caption) VALUES ($1, 'first'), ($1, 'second')`,
      [bob.id],
    );
    expect(await getUserBadgeCount(alice.id)).toBe(2);

    // Mark feed seen → resets the post side. DM side stays 0.
    await request(app)
      .post('/v1/users/me/feed-seen')
      .set('Authorization', `Bearer ${aliceTok}`);
    expect(await getUserBadgeCount(alice.id)).toBe(0);
  });

  test('getUserBadgeCount: includes unread DMs, excludes signal_skdm rows', async () => {
    const { getUserBadgeCount } = require('../src/firebase');
    const { user: alice, token: aliceTok } = await createTestUser();
    const { user: bob, token: bobTok } = await createTestUser();
    await followBoth(
      { token: aliceTok, id: alice.id },
      { token: bobTok, id: bob.id },
    );
    // Mark alice's feed as seen so post side is 0.
    await request(app)
      .post('/v1/users/me/feed-seen')
      .set('Authorization', `Bearer ${aliceTok}`);

    // Open an E2EE direct conversation, bob sends one regular
    // group-style ciphertext + one signal_skdm row addressed to
    // alice. Only the regular row should count.
    const conv = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${bobTok}`)
      .send({ user_id: alice.id, is_e2ee: true });

    await request(app)
      .post(`/v1/conversations/${conv.body.conversation.id}/messages`)
      .set('Authorization', `Bearer ${bobTok}`)
      .send({
        ciphertext: crypto.randomBytes(64).toString('base64'),
        envelope_type: 'signal_1to1',
      });

    expect(await getUserBadgeCount(alice.id)).toBe(1);

    // SKDM row goes through, but doesn't add to the badge.
    await request(app)
      .post(`/v1/conversations/${conv.body.conversation.id}/messages`)
      .set('Authorization', `Bearer ${bobTok}`)
      .send({
        ciphertext: crypto.randomBytes(64).toString('base64'),
        envelope_type: 'signal_skdm',
        recipient_id: alice.id,
      });
    expect(await getUserBadgeCount(alice.id)).toBe(1);

    // Alice marks the conversation read → DM side clears.
    await request(app)
      .post(`/v1/conversations/${conv.body.conversation.id}/read`)
      .set('Authorization', `Bearer ${aliceTok}`);
    expect(await getUserBadgeCount(alice.id)).toBe(0);
  });

  // Helper local to this describe block — mirrors the existing
  // followBoth pattern from elsewhere in the file.
  async function followBoth(a: any, b: any) {
    await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${a.token}`)
      .send({ user_id: b.id });
    await request(app)
      .post('/v1/follows')
      .set('Authorization', `Bearer ${b.token}`)
      .send({ user_id: a.id });
  }

  // Also a tiny helper to log in an existing user record we
  // already have a row for — saves one round-trip per test.
  async function loginAs(user: any) {
    const otpReq = await request(app)
      .post('/v1/auth/request-otp')
      .send({ email: user.email });
    expect(otpReq.status).toBe(200);
    const verify = await request(app)
      .post('/v1/auth/verify-otp')
      .send({ email: user.email, code: '123456' });
    return { token: verify.body.access_token };
  }
});

describe('Notification Preferences', () => {
  test('GET returns defaults when no row exists', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .get('/v1/users/me/notification-preferences')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.notification_preferences).toEqual({
      connections: true,
      posts: true,
      comments: true,
      messages: true,
    });
  });

  test('PATCH updates a single field', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .patch('/v1/users/me/notification-preferences')
      .set('Authorization', `Bearer ${token}`)
      .send({ posts: false });
    expect(res.status).toBe(200);
    expect(res.body.notification_preferences.posts).toBe(false);
    expect(res.body.notification_preferences.connections).toBe(true);
    expect(res.body.notification_preferences.comments).toBe(true);
    expect(res.body.notification_preferences.messages).toBe(true);
  });

  test('PATCH updates multiple fields', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .patch('/v1/users/me/notification-preferences')
      .set('Authorization', `Bearer ${token}`)
      .send({ posts: false, messages: false });
    expect(res.status).toBe(200);
    expect(res.body.notification_preferences.posts).toBe(false);
    expect(res.body.notification_preferences.messages).toBe(false);
    expect(res.body.notification_preferences.connections).toBe(true);
    expect(res.body.notification_preferences.comments).toBe(true);
  });

  test('GET reflects changes after PATCH', async () => {
    const { token } = await createTestUser();

    await request(app)
      .patch('/v1/users/me/notification-preferences')
      .set('Authorization', `Bearer ${token}`)
      .send({ comments: false });

    const res = await request(app)
      .get('/v1/users/me/notification-preferences')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.notification_preferences.comments).toBe(false);
    expect(res.body.notification_preferences.connections).toBe(true);
  });

  test('PATCH with no valid fields returns 400', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .patch('/v1/users/me/notification-preferences')
      .set('Authorization', `Bearer ${token}`)
      .send({});
    expect(res.status).toBe(400);
  });

  test('PATCH can re-enable a previously disabled preference', async () => {
    const { token } = await createTestUser();

    // Disable
    await request(app)
      .patch('/v1/users/me/notification-preferences')
      .set('Authorization', `Bearer ${token}`)
      .send({ posts: false });

    // Re-enable
    const res = await request(app)
      .patch('/v1/users/me/notification-preferences')
      .set('Authorization', `Bearer ${token}`)
      .send({ posts: true });
    expect(res.status).toBe(200);
    expect(res.body.notification_preferences.posts).toBe(true);
  });
});

// ==================== HEALTH & DOCS ====================
describe('Health & Docs', () => {
  test('GET /health returns ok', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });

  test('GET /openapi.json returns OpenAPI spec', async () => {
    const res = await request(app).get('/openapi.json');
    expect(res.status).toBe(200);
    expect(res.body.openapi).toBe('3.0.3');
    expect(res.body.info.title).toBe('A/SIDE API');
  });

  test('GET /docs serves Swagger UI', async () => {
    const res = await request(app).get('/docs/');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('text/html');
  });

  test('CORS allows configured origins', async () => {
    const res = await request(app)
      .get('/health')
      .set('Origin', 'http://localhost:3000');
    expect(res.status).toBe(200);
    expect(res.headers['access-control-allow-origin']).toBe('http://localhost:3000');
  });

  test('CORS omits allow-origin for disallowed origins', async () => {
    const res = await request(app)
      .get('/health')
      .set('Origin', 'https://example.invalid');
    expect(res.status).toBe(200);
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
  });
});

// ==================== REVENUECAT WEBHOOKS ====================
describe('RevenueCat Webhooks', () => {
  test('POST /v1/webhooks/revenuecat rejects missing auth', async () => {
    const res = await request(app)
      .post('/v1/webhooks/revenuecat')
      .send({ event: { id: 'evt1', type: 'INITIAL_PURCHASE', app_user_id: 'x', product_id: 'aside_pro_yearly' } });
    expect(res.status).toBe(401);
  });

  test('POST /v1/webhooks/revenuecat rejects wrong secret', async () => {
    const { config } = require('../src/config');
    const originalSecret = config.revenuecatWebhookSecret;
    config.revenuecatWebhookSecret = 'test-secret';
    try {
      const res = await request(app)
        .post('/v1/webhooks/revenuecat')
        .set('Authorization', 'Bearer wrong-secret')
        .send({ event: { id: 'evt2', type: 'INITIAL_PURCHASE', app_user_id: 'x', product_id: 'aside_pro_yearly' } });
      expect(res.status).toBe(401);
    } finally {
      config.revenuecatWebhookSecret = originalSecret;
    }
  });

  test('POST /v1/webhooks/revenuecat with INITIAL_PURCHASE activates subscription', async () => {
    // Set the webhook secret for this test
    const { config } = require('../src/config');
    const originalSecret = config.revenuecatWebhookSecret;
    config.revenuecatWebhookSecret = 'test-secret';

    const { user } = await createTestUser();

    const res = await request(app)
      .post('/v1/webhooks/revenuecat')
      .set('Authorization', 'Bearer test-secret')
      .send({
        event: {
          id: `evt-${Date.now()}-activate`,
          type: 'INITIAL_PURCHASE',
          app_user_id: user.id,
          product_id: 'aside_pro_yearly',
          expiration_at_ms: Date.now() + 365 * 24 * 60 * 60 * 1000,
        },
      });
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');

    // Verify user is now active with pro_individual plan
    const { rows } = await query('SELECT subscription_status, subscription_plan FROM users WHERE id = $1', [user.id]);
    expect(rows[0].subscription_status).toBe('active');
    expect(rows[0].subscription_plan).toBe('pro_individual');

    config.revenuecatWebhookSecret = originalSecret;
  });

  test('POST /v1/webhooks/revenuecat duplicate event is idempotent', async () => {
    const { config } = require('../src/config');
    const originalSecret = config.revenuecatWebhookSecret;
    config.revenuecatWebhookSecret = 'test-secret';

    const { user } = await createTestUser();
    const eventId = `evt-${Date.now()}-dup`;

    // First call
    await request(app)
      .post('/v1/webhooks/revenuecat')
      .set('Authorization', 'Bearer test-secret')
      .send({ event: { id: eventId, type: 'INITIAL_PURCHASE', app_user_id: user.id, product_id: 'aside_pro_yearly' } });

    // Second call with same event ID
    const res = await request(app)
      .post('/v1/webhooks/revenuecat')
      .set('Authorization', 'Bearer test-secret')
      .send({ event: { id: eventId, type: 'INITIAL_PURCHASE', app_user_id: user.id, product_id: 'aside_pro_yearly' } });

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('already_processed');

    config.revenuecatWebhookSecret = originalSecret;
  });

  test('EXPIRATION event reverts user to free', async () => {
    const { config } = require('../src/config');
    const originalSecret = config.revenuecatWebhookSecret;
    config.revenuecatWebhookSecret = 'test-secret';

    const { user } = await createTestUser({ subscription_status: 'active' });
    await query("UPDATE users SET subscription_plan = 'pro_individual' WHERE id = $1", [user.id]);

    const res = await request(app)
      .post('/v1/webhooks/revenuecat')
      .set('Authorization', 'Bearer test-secret')
      .send({
        event: { id: `evt-${Date.now()}-exp`, type: 'EXPIRATION', app_user_id: user.id, product_id: 'aside_pro_yearly' },
      });
    expect(res.status).toBe(200);

    const { rows } = await query('SELECT subscription_status, subscription_plan FROM users WHERE id = $1', [user.id]);
    expect(rows[0].subscription_status).toBe('expired');
    expect(rows[0].subscription_plan).toBe('free');

    config.revenuecatWebhookSecret = originalSecret;
  });

  test('Family plan purchase propagates to members', async () => {
    const { config } = require('../src/config');
    const originalSecret = config.revenuecatWebhookSecret;
    config.revenuecatWebhookSecret = 'test-secret';

    const owner = await createTestUser();
    const member = await createTestUser();

    // Create family group and add member
    const { rows: fg } = await query(
      'INSERT INTO family_groups (owner_id) VALUES ($1) RETURNING id',
      [owner.user.id],
    );
    await query('UPDATE users SET family_group_id = $2 WHERE id = $1', [owner.user.id, fg[0].id]);
    await query('UPDATE users SET family_group_id = $2 WHERE id = $1', [member.user.id, fg[0].id]);

    // Activate family plan for owner
    const res = await request(app)
      .post('/v1/webhooks/revenuecat')
      .set('Authorization', 'Bearer test-secret')
      .send({
        event: {
          id: `evt-${Date.now()}-fam`,
          type: 'INITIAL_PURCHASE',
          app_user_id: owner.user.id,
          product_id: 'aside_pro_family_yearly',
        },
      });
    expect(res.status).toBe(200);

    // Verify member also got activated
    const { rows } = await query('SELECT subscription_status, subscription_plan FROM users WHERE id = $1', [member.user.id]);
    expect(rows[0].subscription_status).toBe('active');
    expect(rows[0].subscription_plan).toBe('pro_family');

    config.revenuecatWebhookSecret = originalSecret;
  });

  test('Google annual base plan product IDs map to the right plan', async () => {
    const { config } = require('../src/config');
    const originalSecret = config.revenuecatWebhookSecret;
    config.revenuecatWebhookSecret = 'test-secret';

    const { user } = await createTestUser();

    const res = await request(app)
      .post('/v1/webhooks/revenuecat')
      .set('Authorization', 'Bearer test-secret')
      .send({
        event: {
          id: `evt-${Date.now()}-google-annual`,
          type: 'INITIAL_PURCHASE',
          app_user_id: user.id,
          product_id: 'aside_pro_yearly:annual',
          expiration_at_ms: Date.now() + 365 * 24 * 60 * 60 * 1000,
        },
      });
    expect(res.status).toBe(200);

    const { rows } = await query('SELECT subscription_status, subscription_plan FROM users WHERE id = $1', [user.id]);
    expect(rows[0].subscription_status).toBe('active');
    expect(rows[0].subscription_plan).toBe('pro_individual');

    config.revenuecatWebhookSecret = originalSecret;
  });
});

// ==================== SUBSCRIPTION STATUS & FAMILY ====================
describe('Subscription Endpoints', () => {
  test('GET /v1/subscriptions/status returns defaults for free user', async () => {
    const { token } = await createTestUser();
    const res = await request(app)
      .get('/v1/subscriptions/status')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body.subscription.status).toBe('free');
    expect(res.body.subscription.plan).toBe('free');
    expect(res.body.subscription.family).toBeNull();
  });

  test('Family member add/remove flow', async () => {
    const owner = await createTestUser({ subscription_status: 'active' });
    await query("UPDATE users SET subscription_plan = 'pro_family' WHERE id = $1", [owner.user.id]);
    const member = await createTestUser();

    // Add member
    const addRes = await request(app)
      .post('/v1/subscriptions/family/members')
      .set('Authorization', `Bearer ${owner.token}`)
      .send({ user_id: member.user.id });
    expect(addRes.status).toBe(200);
    expect(addRes.body.status).toBe('added');

    // Verify member status
    const { rows: mRows } = await query(
      'SELECT subscription_status, subscription_plan, family_group_id FROM users WHERE id = $1',
      [member.user.id],
    );
    expect(mRows[0].subscription_status).toBe('active');
    expect(mRows[0].subscription_plan).toBe('pro_family');
    expect(mRows[0].family_group_id).not.toBeNull();

    // Check status endpoint shows family info
    const statusRes = await request(app)
      .get('/v1/subscriptions/status')
      .set('Authorization', `Bearer ${owner.token}`);
    expect(statusRes.body.subscription.family).not.toBeNull();
    expect(statusRes.body.subscription.family.is_owner).toBe(true);
    expect(statusRes.body.subscription.family.member_count).toBe(2);

    // Remove member
    const removeRes = await request(app)
      .delete(`/v1/subscriptions/family/members/${member.user.id}`)
      .set('Authorization', `Bearer ${owner.token}`);
    expect(removeRes.status).toBe(200);

    // Verify member reverted to free
    const { rows: mRows2 } = await query(
      'SELECT subscription_status, subscription_plan, family_group_id FROM users WHERE id = $1',
      [member.user.id],
    );
    expect(mRows2[0].subscription_status).toBe('free');
    expect(mRows2[0].subscription_plan).toBe('free');
    expect(mRows2[0].family_group_id).toBeNull();
  });

  test('Max family members enforced', async () => {
    const owner = await createTestUser({ subscription_status: 'active' });
    await query("UPDATE users SET subscription_plan = 'pro_family' WHERE id = $1", [owner.user.id]);

    // Add 5 members (total 6 including owner)
    for (let i = 0; i < 5; i++) {
      const m = await createTestUser();
      const res = await request(app)
        .post('/v1/subscriptions/family/members')
        .set('Authorization', `Bearer ${owner.token}`)
        .send({ user_id: m.user.id });
      expect(res.status).toBe(200);
    }

    // 6th member should fail
    const extra = await createTestUser();
    const res = await request(app)
      .post('/v1/subscriptions/family/members')
      .set('Authorization', `Bearer ${owner.token}`)
      .send({ user_id: extra.user.id });
    expect(res.status).toBe(400);
  });

  test('Non-owner cannot add family members', async () => {
    const notOwner = await createTestUser();
    const target = await createTestUser();

    const res = await request(app)
      .post('/v1/subscriptions/family/members')
      .set('Authorization', `Bearer ${notOwner.token}`)
      .send({ user_id: target.user.id });
    expect(res.status).toBe(403);
  });

  test('Member can leave family voluntarily', async () => {
    const owner = await createTestUser({ subscription_status: 'active' });
    await query("UPDATE users SET subscription_plan = 'pro_family' WHERE id = $1", [owner.user.id]);
    const member = await createTestUser();

    // Add then leave
    await request(app)
      .post('/v1/subscriptions/family/members')
      .set('Authorization', `Bearer ${owner.token}`)
      .send({ user_id: member.user.id });

    const leaveRes = await request(app)
      .post('/v1/subscriptions/family/leave')
      .set('Authorization', `Bearer ${member.token}`);
    expect(leaveRes.status).toBe(200);

    const { rows } = await query('SELECT subscription_status, family_group_id FROM users WHERE id = $1', [member.user.id]);
    expect(rows[0].subscription_status).toBe('free');
    expect(rows[0].family_group_id).toBeNull();
  });
});

// ==================== MESSAGE HISTORY GATING ====================
describe('Message History Gating', () => {
  test('Free user cannot see messages older than 30 days', async () => {
    const userA = await createTestUser();
    const userB = await createTestUser();
    await createMutualFollow(userA.user.id, userB.user.id);

    // Create conversation
    const convoRes = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${userA.token}`)
      .send({ user_id: userB.user.id });
    const convoId = convoRes.body.conversation.id;

    // Insert an old message (35 days ago)
    await query(
      `INSERT INTO messages (conversation_id, sender_id, body, created_at)
       VALUES ($1, $2, 'old message', NOW() - INTERVAL '35 days')`,
      [convoId, userB.user.id],
    );

    // Insert a recent message
    await query(
      `INSERT INTO messages (conversation_id, sender_id, body, created_at)
       VALUES ($1, $2, 'new message', NOW())`,
      [convoId, userB.user.id],
    );

    // Free user should only see recent message
    const res = await request(app)
      .get(`/v1/conversations/${convoId}/messages`)
      .set('Authorization', `Bearer ${userA.token}`);
    expect(res.status).toBe(200);
    expect(res.body.messages.length).toBe(1);
    expect(res.body.messages[0].body).toBe('new message');
    expect(res.body.has_older_messages).toBe(true);
  });

  test('Active user can see all messages', async () => {
    const userA = await createTestUser({ subscription_status: 'active' });
    const userB = await createTestUser();
    await createMutualFollow(userA.user.id, userB.user.id);

    // Create conversation
    const convoRes = await request(app)
      .post('/v1/conversations')
      .set('Authorization', `Bearer ${userA.token}`)
      .send({ user_id: userB.user.id });
    const convoId = convoRes.body.conversation.id;

    // Insert old + new messages
    await query(
      `INSERT INTO messages (conversation_id, sender_id, body, created_at)
       VALUES ($1, $2, 'old message', NOW() - INTERVAL '35 days')`,
      [convoId, userB.user.id],
    );
    await query(
      `INSERT INTO messages (conversation_id, sender_id, body, created_at)
       VALUES ($1, $2, 'new message', NOW())`,
      [convoId, userB.user.id],
    );

    // Active user should see both
    const res = await request(app)
      .get(`/v1/conversations/${convoId}/messages`)
      .set('Authorization', `Bearer ${userA.token}`);
    expect(res.status).toBe(200);
    expect(res.body.messages.length).toBe(2);
    expect(res.body.has_older_messages).toBe(false);
  });
});
