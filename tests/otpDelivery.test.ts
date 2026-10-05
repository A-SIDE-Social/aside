import crypto from 'crypto';
import request from 'supertest';
import { app, pool, query, setupTestServer } from './helpers';
import { config } from '../src/config';

const mockSendEmail = jest.fn();
jest.mock('postmark', () => ({ ServerClient: jest.fn().mockImplementation(() => ({ sendEmail: mockSendEmail })) }));
setupTestServer();

const original = { nodeEnv: config.nodeEnv, devOtp: config.devOtp,
  devOtpAllowedEmails: config.devOtpAllowedEmails, postmarkApiToken: config.postmarkApiToken,
  adminUserIds: config.adminUserIds };
let email = '';
let testNumber = 0;
let warning: jest.SpyInstance;
const hash = (code: string) => crypto.createHash('sha256').update(code).digest('hex');
const requestOtp = (address = email) => request(app).post('/v1/auth/request-otp').send({ email: address });
const sentCode = (index = 0): string => mockSendEmail.mock.calls[index][0].Subject.slice(0, 6);
const otpRows = async () => (await query('SELECT *, expires_at > clock_timestamp() AS valid FROM email_otps WHERE email = $1', [email])).rows;
const rejection = () => Object.assign(new Error('Private provider message must not be logged'), { statusCode: 422, code: 406 });
const deferred = () => {
  let resolve!: () => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<void>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};

beforeEach(async () => {
  email = `otp-delivery-${++testNumber}@example.com`;
  await query('DELETE FROM email_otps');
  config.nodeEnv = 'production';
  config.devOtp = '';
  config.devOtpAllowedEmails = [];
  config.postmarkApiToken = 'isolated-test-token';
  mockSendEmail.mockReset().mockResolvedValue({ ErrorCode: 0 });
  warning = jest.spyOn(console, 'warn').mockImplementation(() => {});
});
afterEach(() => { Object.assign(config, original); warning.mockRestore(); });

test('a successfully sent code can complete registration and is consumed', async () => {
  await requestOtp().expect(200);
  expect(mockSendEmail).toHaveBeenCalledTimes(1);
  expect((await otpRows())[0]).toMatchObject({ code_hash: hash(sentCode()), valid: true });
  await request(app).post('/v1/auth/verify-otp').send({ email, code: sentCode(), display_name: 'OTP Test' }).expect(200);
  expect(await otpRows()).toHaveLength(0);
});

test.each([
  [422, 406, 422], [422, 300, 503], [401, 10, 503], [429, 0, 503],
])('a definite provider rejection (%i/%i) expires the code but retains the cooldown', async (statusCode, code, expected) => {
  mockSendEmail.mockRejectedValue({ statusCode, code });
  await requestOtp().expect(expected);
  expect((await otpRows())[0].valid).toBe(false);
  await request(app).post('/v1/auth/verify-otp').send({ email, code: sentCode() }).expect(400);
  await requestOtp().expect(429);
  expect(mockSendEmail).toHaveBeenCalledTimes(1);
  await query("UPDATE email_otps SET created_at = clock_timestamp() - INTERVAL '31 seconds' WHERE email = $1", [email]);
  mockSendEmail.mockResolvedValue({ ErrorCode: 0 });
  await requestOtp().expect(200);
  expect(mockSendEmail).toHaveBeenCalledTimes(2);
  expect((await otpRows())[0].valid).toBe(true);
});

test('an uncertain timeout preserves an accepted code without retrying the send', async () => {
  mockSendEmail.mockRejectedValue(Object.assign(new Error('Simulated timeout'), { statusCode: 0, code: 0 }));
  await requestOtp().expect(503);
  expect((await otpRows())[0].valid).toBe(true);
  await requestOtp().expect(429);
  expect(mockSendEmail).toHaveBeenCalledTimes(1);
  await request(app).post('/v1/auth/verify-otp').send({ email, code: sentCode(), display_name: 'OTP Test' }).expect(200);
});

test('concurrent requests issue one code and do not hold a database connection during delivery', async () => {
  const started = deferred();
  const delivery = deferred();
  mockSendEmail.mockImplementationOnce(() => { started.resolve(); return delivery.promise; });
  const first = requestOtp().then(response => response);
  await started.promise;
  const competing = await Promise.all(Array.from({ length: 4 }, () => requestOtp()));
  expect(competing.map(response => response.status)).toEqual([429, 429, 429, 429]);
  expect(pool.idleCount).toBe(pool.totalCount);
  expect(await otpRows()).toHaveLength(1);
  delivery.resolve();
  expect((await first).status).toBe(200);
  expect(mockSendEmail).toHaveBeenCalledTimes(1);
});

test('simultaneous first requests cannot both pass the cooldown check', async () => {
  // Make the old check/delete/insert race deterministic: peers see no committed
  // row while the first insert is pending unless issuance holds an address lock.
  await query(`CREATE FUNCTION slow_otp_insert() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN PERFORM pg_sleep(0.1); RETURN NEW; END $$`);
  await query('CREATE TRIGGER slow_otp_insert BEFORE INSERT ON email_otps FOR EACH ROW EXECUTE FUNCTION slow_otp_insert()');
  try {
    const responses = await Promise.all(Array.from({ length: 5 }, () => requestOtp()));
    expect(responses.map(response => response.status).sort()).toEqual([200, 429, 429, 429, 429]);
    expect(mockSendEmail).toHaveBeenCalledTimes(1);
    expect(await otpRows()).toHaveLength(1);
  } finally {
    await query('DROP TRIGGER slow_otp_insert ON email_otps');
    await query('DROP FUNCTION slow_otp_insert()');
  }
});

test('missing production provider configuration expires the unsent code and preserves the cooldown', async () => {
  config.postmarkApiToken = '';
  await requestOtp().expect(503);
  expect((await otpRows())[0].valid).toBe(false);
  await requestOtp().expect(429);
  expect(mockSendEmail).not.toHaveBeenCalled();
});

test('a delayed failure cannot expire a newer successfully delivered OTP', async () => {
  const started = deferred();
  const delivery = deferred();
  mockSendEmail.mockImplementationOnce(() => { started.resolve(); return delivery.promise; });
  const first = requestOtp().then(response => response);
  await started.promise;
  const firstId = (await otpRows())[0].id;
  await query("UPDATE email_otps SET created_at = clock_timestamp() - INTERVAL '31 seconds' WHERE id = $1", [firstId]);
  await requestOtp().expect(200);
  const secondId = (await otpRows())[0].id;
  expect(secondId).not.toBe(firstId);
  delivery.reject(rejection());
  expect((await first).status).toBe(422);
  expect((await otpRows())[0]).toMatchObject({ id: secondId, valid: true, code_hash: hash(sentCode(1)) });
});

test('cleanup failure is diagnosed without replacing the provider error or losing the cooldown', async () => {
  await query(`CREATE FUNCTION reject_otp_expiry() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'simulated cleanup failure'; END $$`);
  await query('CREATE TRIGGER reject_otp_expiry BEFORE UPDATE OF expires_at ON email_otps FOR EACH ROW EXECUTE FUNCTION reject_otp_expiry()');
  try {
    mockSendEmail.mockRejectedValue(rejection());
    await requestOtp().expect(422);
    await requestOtp().expect(429);
    expect(warning).toHaveBeenCalledWith('[OTP] Failed to expire rejected code');
    expect(JSON.stringify(warning.mock.calls)).not.toContain('Private provider message');
  } finally {
    await query('DROP TRIGGER reject_otp_expiry ON email_otps');
    await query('DROP FUNCTION reject_otp_expiry()');
  }
});

test('replacement failure rolls back to the previous OTP without sending', async () => {
  await requestOtp().expect(200);
  const previous = (await otpRows())[0];
  await query("UPDATE email_otps SET created_at = clock_timestamp() - INTERVAL '31 seconds' WHERE id = $1", [previous.id]);
  await query(`CREATE FUNCTION reject_otp_insert() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'simulated insert failure'; END $$`);
  await query('CREATE TRIGGER reject_otp_insert BEFORE INSERT ON email_otps FOR EACH ROW EXECUTE FUNCTION reject_otp_insert()');
  const log = jest.spyOn(console, 'error').mockImplementation(() => {});
  try {
    await requestOtp().expect(500);
    expect((await otpRows())[0]).toMatchObject({ id: previous.id, code_hash: previous.code_hash, valid: true });
    expect(mockSendEmail).toHaveBeenCalledTimes(1);
  } finally {
    log.mockRestore();
    await query('DROP TRIGGER reject_otp_insert ON email_otps');
    await query('DROP FUNCTION reject_otp_insert()');
  }
});

test('reviewer bypass is restricted to the production allowlist', async () => {
  config.devOtp = '123456';
  config.devOtpAllowedEmails = [email];
  await requestOtp().expect(200);
  expect(mockSendEmail).not.toHaveBeenCalled();
  expect((await otpRows())[0].code_hash).toBe(hash('123456'));
  await requestOtp('ordinary-user@example.com').expect(200);
  expect(mockSendEmail).toHaveBeenCalledTimes(1);
});

test('admin and mobile requests share the cooldown without exposing admin eligibility', async () => {
  const { rows } = await query(`INSERT INTO users (username, display_name, email) VALUES ('otp_admin', 'OTP Admin', $1) RETURNING id`, ['otp-admin@example.com']);
  config.adminUserIds = [rows[0].id];
  const adminRequest = (address: string) => request(app).post('/admin/login/request-otp').type('form').send({ email: address });
  await adminRequest('otp-admin@example.com').expect(200);
  await requestOtp('otp-admin@example.com').expect(429);
  const repeated = await adminRequest('otp-admin@example.com').expect(200);
  const unknown = await adminRequest('not-an-admin@example.com').expect(200);
  expect(repeated.text).toContain('Enter code');
  expect(unknown.text).toContain('Enter code');
  expect(mockSendEmail).toHaveBeenCalledTimes(1);
});
