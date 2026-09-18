import fs from 'fs';
import path from 'path';
import express from 'express';
import request from 'supertest';
import { pool, query } from '../src/db/pool';
import { newsletterRouter } from '../src/routes/newsletter';
import { cleanupPendingSignups, hashToken } from '../src/newsletter/service';

const app = express().use('/newsletter', newsletterRouter);
const originalFetch = global.fetch;
const mockedFetch = jest.fn();
const site = 'https://www.example.com';
const api = 'https://api.example.com';
const env = {
  NEWSLETTER_RESEND_API_KEY: 'test-contact-key', RESEND_API_KEY: 'test-send-key',
  NEWSLETTER_SEGMENT_ID: 'notes-segment', NEWSLETTER_TOPIC_ID: 'notes-topic',
  NEWSLETTER_API_URL: api, PUBLIC_APP_URL: site, NEWSLETTER_ALLOWED_ORIGINS: site,
  MARKETING_FROM_EMAIL: 'notes@example.com', MARKETING_REPLY_TO_EMAIL: 'reply@example.com',
  NEWSLETTER_FROM_EMAIL: 'Notes <notes@example.com>', NEWSLETTER_REPLY_TO_EMAIL: 'reply@example.com',
  NEWSLETTER_POSTAL_ADDRESS: 'Example Company, 1 Example Street',
};
const savedEnv = Object.fromEntries(Object.keys(env).map(key => [key, process.env[key]]));
const ok = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status });
const postSignup = (body: object = { email: 'reader@example.com', consent: 'yes' }) =>
  request(app).post('/newsletter/subscribe').set('Origin', site).type('form').send(body);
const confirm = (token: string) => request(app).post('/newsletter/confirm').set('Origin', api).type('form').send({ token });
const calls = () => mockedFetch.mock.calls.map(([url, options]) => ({ url, ...options, body: options.body ? JSON.parse(options.body) : undefined }));
async function newToken() {
  expect((await postSignup()).status).toBe(200);
  return calls().find(call => call.url.endsWith('/emails'))!.body.text.match(/token=([a-f0-9]{64})/)[1] as string;
}

beforeAll(async () => {
  // Use the same explicitly configured disposable database as the other API tests.
  if (!process.env.DATABASE_URL) throw new Error('Set DATABASE_URL to a disposable test database');
  const exists = await query("SELECT to_regclass('newsletter_signups') AS name");
  if (!exists.rows[0].name) await query(fs.readFileSync(path.join(__dirname, '../src/db/migrations/029_newsletter_signups.sql'), 'utf8'));
  global.fetch = mockedFetch;
});
beforeEach(async () => {
  Object.assign(process.env, env);
  await query('TRUNCATE newsletter_signups');
  mockedFetch.mockReset().mockResolvedValue(ok({ id: 'sent-email' }));
});
afterAll(async () => {
  global.fetch = originalFetch;
  for (const [key, value] of Object.entries(savedEnv)) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  await pool.end();
});

test('requires explicit consent and rejects malformed addresses and foreign origins', async () => {
  expect((await postSignup({ email: 'reader@example.com' })).status).toBe(400);
  expect((await postSignup({ email: 'bad\nBcc:other@example.com', consent: 'yes' })).status).toBe(400);
  expect((await request(app).post('/newsletter/subscribe').set('Origin', 'https://unrelated.example').type('form').send({ email: 'reader@example.com', consent: 'yes' })).status).toBe(403);
  expect(mockedFetch).not.toHaveBeenCalled();
  expect((await query('SELECT * FROM newsletter_signups')).rows).toHaveLength(0);
});

test('honeypot and incomplete configuration cannot add subscribers or send mail', async () => {
  expect((await postSignup({ email: 'reader@example.com', consent: 'yes', website: 'spam' })).status).toBe(200);
  delete process.env.NEWSLETTER_TOPIC_ID;
  expect((await postSignup()).status).toBe(503);
  expect(mockedFetch).not.toHaveBeenCalled();
});

test('stores only a token hash; email scanner GET cannot activate a subscriber', async () => {
  const token = await newToken();
  const row = (await query('SELECT * FROM newsletter_signups')).rows[0];
  expect(row.token_hash).toBe(hashToken(token));
  expect(row.confirmed_at).toBeNull();
  expect(row.consent_version).toBe('notes-2026-09-18');
  expect(row.source).toBe('website-notes');
  expect(calls()).toHaveLength(1);
  expect(calls()[0].headers.Authorization).toBe('Bearer test-send-key');
  const response = await request(app).get(`/newsletter/confirm?token=${token}`);
  expect(response.status).toBe(200);
  expect(response.headers['referrer-policy']).toBe('no-referrer');
  expect(response.headers['cache-control']).toBe('no-store');
  expect(mockedFetch).toHaveBeenCalledTimes(1);
  expect((await query('SELECT confirmed_at FROM newsletter_signups')).rows[0].confirmed_at).toBeNull();
});

test('confirmation creates only the Notes segment and explicit topic opt-in', async () => {
  const token = await newToken();
  mockedFetch.mockReset().mockResolvedValueOnce(ok({}, 404)).mockResolvedValueOnce(ok({ id: 'notes-reader' }));
  expect((await confirm(token)).text).toContain('You’re subscribed.');
  expect(calls()[1].body).toEqual({ email: 'reader@example.com', segments: [{ id: 'notes-segment' }], topics: [{ id: 'notes-topic', subscription: 'opt_in' }] });
  expect(calls()[0].headers.Authorization).toBe('Bearer test-contact-key');
  const row = (await query('SELECT * FROM newsletter_signups')).rows[0];
  expect(row.confirmed_at).not.toBeNull();
  expect(row.resend_contact_id).toBe('notes-reader');
  // An old link must never undo a later unsubscribe.
  mockedFetch.mockClear();
  expect((await confirm(token)).text).toContain('already been used');
  expect(mockedFetch).not.toHaveBeenCalled();
});

test('updates only Notes for an existing contact, leaving other topics and global opt-out alone', async () => {
  const token = await newToken();
  mockedFetch.mockReset().mockResolvedValueOnce(ok({ id: 'existing', unsubscribed: false }))
    .mockResolvedValueOnce(ok({ id: 'notes-segment' })).mockResolvedValueOnce(ok({ id: 'notes-topic' }));
  expect((await confirm(token)).status).toBe(200);
  expect(calls().map(call => [call.method, call.url])).toEqual([
    ['GET', 'https://api.resend.com/contacts/reader%40example.com'],
    ['POST', 'https://api.resend.com/contacts/existing/segments/notes-segment'],
    ['PATCH', 'https://api.resend.com/contacts/existing/topics'],
  ]);
  // The REST endpoint expects the array itself, not the SDK's { topics } wrapper.
  expect(calls()[2].body).toEqual([{ id: 'notes-topic', subscription: 'opt_in' }]);
});

test('preserves an existing global unsubscribe without any provider writes', async () => {
  const token = await newToken();
  mockedFetch.mockReset().mockResolvedValueOnce(ok({ id: 'existing', unsubscribed: true }));
  expect((await confirm(token)).status).toBe(409);
  expect(calls()).toHaveLength(1);
  expect(calls()[0].method).toBe('GET');
});

test('invalid and expired tokens cannot activate contacts', async () => {
  const token = await newToken();
  await query("UPDATE newsletter_signups SET expires_at = now() - interval '1 second'");
  mockedFetch.mockClear();
  expect((await confirm(token)).status).toBe(400);
  expect((await confirm('a'.repeat(64))).status).toBe(400);
  expect((await confirm('not-a-token')).status).toBe(400);
  expect(mockedFetch).not.toHaveBeenCalled();
});

test('provider failure leaves confirmation retryable and does not expose recipient details', async () => {
  const token = await newToken();
  const warning = jest.spyOn(console, 'warn').mockImplementation(() => {});
  mockedFetch.mockReset().mockResolvedValueOnce(ok({ message: 'reader@example.com failed' }, 500));
  const response = await confirm(token);
  expect(response.status).toBe(503);
  expect(response.text).not.toContain('reader@example.com');
  expect((await query('SELECT completed_at FROM newsletter_signups')).rows[0].completed_at).toBeNull();
  mockedFetch.mockResolvedValueOnce(ok({}, 404)).mockResolvedValueOnce(ok({ id: 'retry-reader' }));
  expect((await confirm(token)).status).toBe(200);
  warning.mockRestore();
});

test('concurrent confirmation requests activate once', async () => {
  const token = await newToken();
  mockedFetch.mockReset().mockResolvedValueOnce(ok({}, 404)).mockResolvedValueOnce(ok({ id: 'once' }));
  const responses = await Promise.all([confirm(token), confirm(token)]);
  expect(responses.map(response => response.status)).toEqual([200, 200]);
  expect(mockedFetch).toHaveBeenCalledTimes(2);
  expect(responses.filter(response => response.text.includes('already been used'))).toHaveLength(1);
});

test('a partial provider update can be retried without changing other subscriptions', async () => {
  const token = await newToken();
  const warning = jest.spyOn(console, 'warn').mockImplementation(() => {});
  mockedFetch.mockReset().mockResolvedValueOnce(ok({ id: 'existing', unsubscribed: false }))
    .mockResolvedValueOnce(ok({ id: 'notes-segment' })).mockResolvedValueOnce(ok({}, 503));
  expect((await confirm(token)).status).toBe(503);
  expect((await query('SELECT completed_at FROM newsletter_signups')).rows[0].completed_at).toBeNull();
  mockedFetch.mockResolvedValueOnce(ok({ id: 'existing', unsubscribed: false }))
    .mockResolvedValueOnce(ok({ id: 'notes-segment' })).mockResolvedValueOnce(ok({ id: 'notes-topic' }));
  expect((await confirm(token)).status).toBe(200);
  expect(calls().filter(call => call.method === 'PATCH').map(call => call.body)).toEqual([
    [{ id: 'notes-topic', subscription: 'opt_in' }], [{ id: 'notes-topic', subscription: 'opt_in' }],
  ]);
  warning.mockRestore();
});

test('normalizes addresses before the cooldown check', async () => {
  await newToken();
  expect((await postSignup({ email: ' READER@EXAMPLE.COM ', consent: 'yes' })).status).toBe(200);
  expect(mockedFetch).toHaveBeenCalledTimes(1);
  expect((await query('SELECT email FROM newsletter_signups')).rows).toEqual([{ email: 'reader@example.com' }]);
});

test('limits repeat emails, rotates old tokens, and stops after three requests per day', async () => {
  const firstToken = await newToken();
  expect((await postSignup()).status).toBe(200);
  expect(mockedFetch).toHaveBeenCalledTimes(1);
  for (let attempt = 0; attempt < 3; attempt++) {
    await query("UPDATE newsletter_signups SET requested_at = now() - interval '16 minutes'");
    mockedFetch.mockResolvedValueOnce(ok({ id: `email-${attempt}` }));
    await postSignup();
  }
  expect(mockedFetch).toHaveBeenCalledTimes(3);
  expect((await confirm(firstToken)).status).toBe(400);
  expect((await query('SELECT request_count FROM newsletter_signups')).rows[0].request_count).toBe(3);
});

test('cleanup removes old pending requests but retains confirmed consent records', async () => {
  await newToken();
  await query("UPDATE newsletter_signups SET requested_at = now() - interval '8 days'");
  await cleanupPendingSignups();
  expect((await query('SELECT * FROM newsletter_signups')).rows).toHaveLength(0);
  mockedFetch.mockResolvedValueOnce(ok({ id: 'another-email' }));
  await postSignup();
  await query("UPDATE newsletter_signups SET requested_at = now() - interval '8 days', confirmed_at = now()");
  await cleanupPendingSignups();
  expect((await query('SELECT * FROM newsletter_signups')).rows).toHaveLength(1);
});
