/**
 * Admin web UI integration tests.
 *
 * Covers the gating paths (no cookie / non-admin cookie) and the
 * change-email happy path, which exercises the full mutation +
 * audit-log + email_otps cleanup chain that this dashboard's
 * primary purpose is to encapsulate.
 */

import request from 'supertest';
import http from 'http';
import { app, pool, query, generateAccessToken, setupTestServer } from './helpers';
import { config } from '../src/config';

setupTestServer();

// Inline server reference — setupTestServer creates it but doesn't
// expose it; we use supertest(app) directly instead, which works
// equally well for HTTP testing without the live socket.

describe('GET /admin/users — gating', () => {
  test('redirects to /admin/login when no admin cookie', async () => {
    const res = await request(app).get('/admin/users');
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/admin/login');
  });

  test('redirects to /admin/login when cookie is unsigned (raw JWT, no signature)', async () => {
    // Cookie-parser's signed cookies require an `s:value.signature`
    // shape; a plain JWT stuffed in the cookie should be ignored
    // by req.signedCookies and treated as missing.
    const fakeJwt = generateAccessToken('00000000-0000-0000-0000-000000000000');
    const res = await request(app)
      .get('/admin/users')
      .set('Cookie', [`admin_session=${fakeJwt}`]);
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/admin/login');
  });

  test('returns 403 when JWT signs for a non-admin user', async () => {
    // Create a real user, sign a real JWT for them, and send it as
    // a properly *signed* cookie. The middleware should accept the
    // JWT but reject the user_id at the allowlist step.
    const { rows } = await query(
      `INSERT INTO users (username, display_name, email)
       VALUES ('u_nonadmin_${Date.now()}', 'Non-Admin', 'nonadmin@test.com')
       RETURNING id`,
    );
    const nonAdminId = rows[0].id;
    const token = generateAccessToken(nonAdminId);

    // Sign the cookie value the way cookie-parser expects so the
    // middleware actually reads it from req.signedCookies.
    const cookie = signCookie('admin_session', token, config.jwtSecret);

    // Make sure the test user isn't accidentally in adminUserIds.
    config.adminUserIds = [];

    const res = await request(app)
      .get('/admin/users')
      .set('Cookie', [cookie]);

    expect(res.status).toBe(403);
    expect(res.text).toContain('Access denied');
  });
});

describe('POST /admin/users/:id/email — change email happy path', () => {
  test('updates email + email_hash, clears email_otps, writes audit row', async () => {
    // Set up an admin user.
    const { rows: adminRows } = await query(
      `INSERT INTO users (username, display_name, email)
       VALUES ('u_admin_${Date.now()}', 'Admin', 'admin-${Date.now()}@test.com')
       RETURNING id, email`,
    );
    const admin = adminRows[0];
    config.adminUserIds = [admin.id];

    // And a target user we'll change the email of.
    const oldEmail = `old-${Date.now()}@test.com`;
    const newEmail = `new-${Date.now()}@test.com`;
    const { rows: targetRows } = await query(
      `INSERT INTO users (username, display_name, email)
       VALUES ('u_target_${Date.now()}', 'Target', $1)
       RETURNING id`,
      [oldEmail],
    );
    const targetId = targetRows[0].id;

    // Plant a stale OTP for the OLD email — the change-email
    // handler should clean it up. (This is the dangling-record
    // cleanup that motivated building the dashboard in the first
    // place; if this assertion regresses, the manual psql workflow
    // is back.)
    await query(
      `INSERT INTO email_otps (email, code_hash, expires_at)
       VALUES ($1, 'sha256-of-fake', NOW() + INTERVAL '10 minutes')`,
      [oldEmail],
    );

    // Sign in as admin via the real OTP flow. supertest doesn't
    // expose its cookie jar directly, so we read the Set-Cookie
    // headers manually and re-attach to subsequent requests.
    const requestOtp = await request(app)
      .post('/admin/login/request-otp')
      .type('form')
      .send({ email: admin.email });
    const csrfCookieRaw = pickSetCookie(requestOtp.headers, 'admin_csrf');
    expect(csrfCookieRaw).toBeTruthy();
    const csrfValue = unsignCookieValue(csrfCookieRaw!, config.jwtSecret);
    expect(csrfValue).toBeTruthy();

    const verify = await request(app)
      .post('/admin/login/verify-otp')
      .type('form')
      .set('Cookie', [csrfCookieRaw!])
      .send({ email: admin.email, code: '123456', csrf: csrfValue! });
    expect(verify.status).toBe(302);
    expect(verify.headers.location).toBe('/admin/users');

    const sessionCookie = pickSetCookie(verify.headers, 'admin_session');
    const newCsrfCookie = pickSetCookie(verify.headers, 'admin_csrf');
    expect(sessionCookie).toBeTruthy();
    expect(newCsrfCookie).toBeTruthy();

    // Get the user-detail page so we have a fresh CSRF in the
    // form. (The middleware's render path calls ensureCsrf, but
    // the cookie is already set from login — we just need to
    // know its value to embed in our POST.)
    const csrfForPost = unsignCookieValue(newCsrfCookie!, config.jwtSecret)!;

    const change = await request(app)
      .post(`/admin/users/${targetId}/email`)
      .type('form')
      .set('Cookie', [sessionCookie!, newCsrfCookie!])
      .send({ new_email: newEmail, csrf: csrfForPost });

    expect(change.status).toBe(302);
    expect(change.headers.location).toBe(`/admin/users/${targetId}`);

    // 1. email + email_hash updated
    const { rows: after } = await query(
      `SELECT email, email_hash FROM users WHERE id = $1`,
      [targetId],
    );
    expect(after[0].email).toBe(newEmail);
    expect(after[0].email_hash).toMatch(/^[0-9a-f]{64}$/);
    // Verify it's the SHA-256 of the new email specifically.
    const crypto = await import('crypto');
    const expectedHash = crypto
      .createHash('sha256')
      .update(newEmail.toLowerCase())
      .digest('hex');
    expect(after[0].email_hash).toBe(expectedHash);

    // 2. email_otps for the OLD address cleared
    const { rows: oldOtps } = await query(
      `SELECT 1 FROM email_otps WHERE email = $1`,
      [oldEmail],
    );
    expect(oldOtps.length).toBe(0);

    // 3. Audit row written
    const { rows: audit } = await query(
      `SELECT action, target_user_id, details FROM admin_audit
        WHERE action = 'change_email' AND target_user_id = $1
        ORDER BY created_at DESC LIMIT 1`,
      [targetId],
    );
    expect(audit.length).toBe(1);
    expect(audit[0].details.from).toBe(oldEmail);
    expect(audit[0].details.to).toBe(newEmail);
    expect(audit[0].details.email_hash_recomputed).toBe(true);
  });
});

// ── Cookie helpers ────────────────────────────────────────────────
// cookie-parser uses a custom signing scheme: `s:value.HMAC-SHA256(secret).base64`.
// We need to mint signed cookies for the gating tests and
// unwrap them for the integration test. Reproducing the
// algorithm here keeps the tests independent of cookie-parser's
// internals.

function signCookie(name: string, value: string, secret: string): string {
  // cookie-parser's signed format: `<name>=s:<value>.<HMAC>`
  const cryptoMod = require('crypto');
  const mac = cryptoMod
    .createHmac('sha256', secret)
    .update(value)
    .digest('base64')
    .replace(/=+$/, '');
  return `${name}=s%3A${encodeURIComponent(value)}.${mac}`;
}

function pickSetCookie(headers: Record<string, any>, name: string): string | undefined {
  const raw = headers['set-cookie'];
  if (!raw) return undefined;
  const arr = Array.isArray(raw) ? raw : [raw];
  for (const c of arr) {
    if (c.startsWith(`${name}=`)) {
      // Strip everything after the first `;` (Path, HttpOnly, etc.)
      return c.split(';')[0];
    }
  }
  return undefined;
}

function unsignCookieValue(cookie: string, secret: string): string | null {
  // cookie-parser writes signed cookies as `name=s%3A<value>.<sig>`
  const eq = cookie.indexOf('=');
  if (eq === -1) return null;
  const raw = decodeURIComponent(cookie.slice(eq + 1));
  if (!raw.startsWith('s:')) return null;
  const sigIdx = raw.lastIndexOf('.');
  if (sigIdx === -1) return null;
  const value = raw.slice(2, sigIdx);
  const submittedSig = raw.slice(sigIdx + 1);
  const cryptoMod = require('crypto');
  const expectedSig = cryptoMod
    .createHmac('sha256', secret)
    .update(value)
    .digest('base64')
    .replace(/=+$/, '');
  return submittedSig === expectedSig ? value : null;
}

