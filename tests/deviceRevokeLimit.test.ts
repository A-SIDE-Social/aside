import express from 'express';
import request from 'supertest';

const originalNodeEnv = process.env.NODE_ENV;

afterEach(() => {
  process.env.NODE_ENV = originalNodeEnv;
  jest.resetModules();
});

test('device revocation is capped at ten attempts per minute in production', async () => {
  process.env.NODE_ENV = 'production';
  jest.resetModules();
  const { deviceRevokeLimit } = await import('../src/middleware/rateLimit');
  const app = express();
  app.post('/devices/revoke', deviceRevokeLimit, (_req, res) => res.sendStatus(204));

  for (let attempt = 0; attempt < 10; attempt += 1) {
    await request(app).post('/devices/revoke').expect(204);
  }

  await request(app)
    .post('/devices/revoke')
    .expect(429)
    .expect({ error: 'Too many device revocation attempts, please try again later' });
});
