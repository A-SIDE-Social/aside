/**
 * Marketing-broadcast unit + integration tests.
 *
 * Covers:
 *   1. unsubscribe-token round-trip + tampering rejection
 *   2. allOptedInRecipients respects deleted_at + marketing_opt_in + null email
 *   3. /unsubscribe?token=… flips marketing_opt_in to false
 *   4. /unsubscribe with bad token returns 400
 *
 * Send-orchestration test (mocking Resend) is intentionally skipped:
 * the orchestration is a paced loop over Resend SDK calls, and
 * Resend's own tests cover the SDK. We test the bits that depend on
 * our code: audience selection, token integrity, opt-out plumbing.
 */

import request from 'supertest';
import { app, query, setupTestServer } from './helpers';
import {
  makeUnsubscribeToken,
  verifyUnsubscribeToken,
} from '../src/marketing/unsubscribe-token';
import { allOptedInRecipients } from '../src/marketing/audience';

setupTestServer();

describe('unsubscribe token', () => {
  test('round-trips', () => {
    const userId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    const token = makeUnsubscribeToken(userId);
    expect(verifyUnsubscribeToken(token)).toBe(userId);
  });

  test('rejects tampered token', () => {
    const userId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    const token = makeUnsubscribeToken(userId);
    // Flip the user_id but keep the original signature.
    const tampered = token.replace(userId, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
    expect(verifyUnsubscribeToken(tampered)).toBeNull();
  });

  test('rejects missing dot separator', () => {
    expect(verifyUnsubscribeToken('not-a-token')).toBeNull();
  });

  test('rejects empty / non-string', () => {
    expect(verifyUnsubscribeToken('')).toBeNull();
    expect(verifyUnsubscribeToken('.' as any)).toBeNull();
    expect(verifyUnsubscribeToken('userid.' as any)).toBeNull();
    expect(verifyUnsubscribeToken('.signature' as any)).toBeNull();
  });
});

describe('allOptedInRecipients', () => {
  test('includes opted-in users with email; excludes deleted, opted-out, no-email', async () => {
    const stamp = Date.now();
    // Three users that should appear:
    await query(
      `INSERT INTO users (username, display_name, email, marketing_opt_in)
         VALUES
         ('u_in1_${stamp}', 'In 1', 'in1-${stamp}@test.com', true),
         ('u_in2_${stamp}', 'In 2', 'in2-${stamp}@test.com', true),
         ('u_in3_${stamp}', 'In 3', 'in3-${stamp}@test.com', true)`,
    );
    // One opted-out:
    await query(
      `INSERT INTO users (username, display_name, email, marketing_opt_in)
         VALUES ('u_out_${stamp}', 'Opted Out', 'out-${stamp}@test.com', false)`,
    );
    // One soft-deleted:
    await query(
      `INSERT INTO users (username, display_name, email, marketing_opt_in, deleted_at)
         VALUES ('u_del_${stamp}', 'Deleted', 'del-${stamp}@test.com', true, NOW())`,
    );
    // One with no email (legacy phone-only account):
    await query(
      `INSERT INTO users (username, display_name, email, marketing_opt_in)
         VALUES ('u_nomail_${stamp}', 'No Email', NULL, true)`,
    );

    const recipients = await allOptedInRecipients();
    const emails = recipients.map((r) => r.email);
    expect(emails).toContain(`in1-${stamp}@test.com`);
    expect(emails).toContain(`in2-${stamp}@test.com`);
    expect(emails).toContain(`in3-${stamp}@test.com`);
    expect(emails).not.toContain(`out-${stamp}@test.com`);
    expect(emails).not.toContain(`del-${stamp}@test.com`);
    // Anyone without an email is filtered out:
    expect(emails.every((e) => e !== null && e !== '')).toBe(true);
  });
});

describe('GET /unsubscribe', () => {
  test('valid token flips marketing_opt_in to false', async () => {
    const stamp = Date.now();
    const { rows } = await query(
      `INSERT INTO users (username, display_name, email, marketing_opt_in)
         VALUES ('u_unsub_${stamp}', 'Unsub Tester', 'unsub-${stamp}@test.com', true)
         RETURNING id`,
    );
    const userId = rows[0].id;
    const token = makeUnsubscribeToken(userId);

    const res = await request(app).get(`/unsubscribe?token=${encodeURIComponent(token)}`);
    expect(res.status).toBe(200);
    expect(res.text).toContain("You're unsubscribed");

    const { rows: after } = await query(
      `SELECT marketing_opt_in, marketing_opted_out_at FROM users WHERE id = $1`,
      [userId],
    );
    expect(after[0].marketing_opt_in).toBe(false);
    expect(after[0].marketing_opted_out_at).not.toBeNull();
  });

  test('bad token returns 400', async () => {
    const res = await request(app).get('/unsubscribe?token=garbage');
    expect(res.status).toBe(400);
    expect(res.text).toContain('Link expired or invalid');
  });

  test('missing token returns 400', async () => {
    const res = await request(app).get('/unsubscribe');
    expect(res.status).toBe(400);
  });

  test('POST with form-encoded token works (one-click semantics)', async () => {
    const stamp = Date.now();
    const { rows } = await query(
      `INSERT INTO users (username, display_name, email, marketing_opt_in)
         VALUES ('u_post_${stamp}', 'POST Tester', 'post-${stamp}@test.com', true)
         RETURNING id`,
    );
    const userId = rows[0].id;
    const token = makeUnsubscribeToken(userId);

    // Simulate Gmail's one-click POST.
    const res = await request(app)
      .post('/unsubscribe')
      .type('form')
      .send({ token });
    expect(res.status).toBe(200);

    const { rows: after } = await query(
      `SELECT marketing_opt_in FROM users WHERE id = $1`,
      [userId],
    );
    expect(after[0].marketing_opt_in).toBe(false);
  });
});

