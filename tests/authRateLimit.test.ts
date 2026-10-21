import express from 'express';
import request from 'supertest';

test('the production shared auth budget returns a bounded retry delay without raising its limit', async () => {
  const original = process.env.NODE_ENV;
  let authLimit: express.RequestHandler;
  try {
    process.env.NODE_ENV = 'production';
    jest.isolateModules(() => { authLimit = require('../src/middleware/rateLimit').authLimit; });
  } finally {
    process.env.NODE_ENV = original;
  }
  const local = express();
  local.post(['/request-otp', '/verify-otp'], authLimit!, (_req, res) => { res.sendStatus(200); });
  for (let i = 0; i < 50; i++) {
    await request(local).post(i % 2 ? '/verify-otp' : '/request-otp').expect(200);
  }
  const blocked = await request(local).post('/request-otp').expect(429);
  expect(blocked.body.code).toBe('auth_rate_limited');
  expect(blocked.body.retry_after_seconds).toBeGreaterThan(0);
  expect(blocked.body.retry_after_seconds).toBeLessThanOrEqual(900);
  expect(Number(blocked.headers['retry-after'])).toBe(blocked.body.retry_after_seconds);
  await request(local).post('/verify-otp').expect(429);
});
