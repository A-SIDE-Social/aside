import express from 'express';
import request from 'supertest';
import { errorHandler } from '../src/middleware/errorHandler';

function bodyApp() {
  return express().use(express.json({ limit: '64b' }))
    .post('/body', (_req, res) => res.sendStatus(204)).use(errorHandler);
}

test('malformed JSON returns 400 without reflecting or logging its contents', async () => {
  const log = jest.spyOn(console, 'error').mockImplementation(() => {});
  try {
    const response = await request(bodyApp()).post('/body').type('json').send('{"email":"private@example.com"');
    expect(response.status).toBe(400);
    expect(response.body).toEqual({ error: 'Invalid JSON body' });
    expect(log).not.toHaveBeenCalled();
  } finally { log.mockRestore(); }
});

test('oversized JSON returns 413', async () => {
  const response = await request(bodyApp()).post('/body').send({ text: 'x'.repeat(100) });
  expect(response.status).toBe(413);
  expect(response.body).toEqual({ error: 'Request body is too large' });
});

test('unsupported body charset returns 415', async () => {
  expect((await request(bodyApp()).post('/body').set('Content-Type', 'application/json; charset=bogus').send('{}')).status).toBe(415);
});

test('arbitrary downstream status is not trusted as a client error', async () => {
  const log = jest.spyOn(console, 'error').mockImplementation(() => {});
  try {
    const app = express().get('/', () => { throw Object.assign(new Error('upstream detail'), { status: 401 }); }).use(errorHandler);
    const response = await request(app).get('/');
    expect(response.status).toBe(500);
    expect(response.body).toEqual({ error: 'Internal server error' });
  } finally { log.mockRestore(); }
});

test('delegates errors after headers have already been sent', () => {
  const err = new Error('late failure');
  const next = jest.fn();
  errorHandler(err, {} as any, { headersSent: true } as any, next);
  expect(next).toHaveBeenCalledWith(err);
});
