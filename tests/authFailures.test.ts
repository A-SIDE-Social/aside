import express from 'express';
import request from 'supertest';
import authRouter from '../src/routes/auth';
import { query } from '../src/db/pool';
import { sendOtpEmail } from '../src/email';
import { errorHandler } from '../src/middleware/errorHandler';

jest.mock('../src/db/pool', () => ({ query: jest.fn(), getClient: jest.fn() }));
jest.mock('../src/email', () => ({ sendOtpEmail: jest.fn() }));
jest.mock('../src/firebase', () => ({}));

const app = express().use(express.json()).use('/auth', authRouter).use(errorHandler);
beforeEach(() => { jest.clearAllMocks(); });

describe.each(['request-otp', 'verify-otp'])('%s input validation', (endpoint) => {
  test.each([null, 42, true, {}, [], ['person@example.com'], '', '   ', 'not-an-address',
    'a@example.com,b@example.com', 'a@b.com\nBcc:other@example.com', '.a@example.com',
    'a..b@example.com', 'a'.repeat(65) + '@example.com', 'a@' + 'b'.repeat(250) + '.com'])
  ('rejects invalid email %j before accessing the database or provider', async (email) => {
    const response = await request(app).post('/auth/' + endpoint).send({ email, code: '123456' });
    expect(response.status).toBe(400);
    expect(query).not.toHaveBeenCalled();
    expect(sendOtpEmail).not.toHaveBeenCalled();
  });

  test('rejects a missing request body', async () => {
    expect((await request(app).post('/auth/' + endpoint)).status).toBe(400);
    expect(query).not.toHaveBeenCalled();
  });
});

test.each([null, 123456, true, {}, [], '', 'a'.repeat(129)])('rejects invalid code %j before consuming an attempt', async (code) => {
  expect((await request(app).post('/auth/verify-otp').send({ email: 'person@example.com', code })).status).toBe(400);
  expect(query).not.toHaveBeenCalled();
});

test('normalizes a valid email before checking cooldown', async () => {
  (query as jest.Mock).mockResolvedValue({ rows: [{}] });
  expect((await request(app).post('/auth/request-otp').send({ email: ' Person+tag@Example.com ' })).status).toBe(429);
  expect(query).toHaveBeenCalledWith(expect.any(String), ['person+tag@example.com']);
  expect(sendOtpEmail).not.toHaveBeenCalled();
});
