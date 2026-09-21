import express from 'express';
import request from 'supertest';
import { Histogram } from '@prometheus-io/client';
import { measureHttp, measureMessageHandler, measureStage, performanceRegistry, startPerformanceServer } from '../src/performance';
import { AppError, errorHandler } from '../src/middleware/errorHandler';
import { EventEmitter } from 'events';

beforeEach(() => { process.env.PERFORMANCE_METRICS = '1'; performanceRegistry.resetMetrics(); });
afterAll(() => { delete process.env.PERFORMANCE_METRICS; });

function testApp() {
  const app = express();
  app.use(measureHttp);
  const root = express.Router();
  const users = express.Router();
  users.get('/:id', (_req, res) => res.json({ ok: true }));
  root.use('/users', users);
  root.get('/posts/:id/comments', (_req, res) => res.status(503).end());
  app.use('/v1', root);
  app.get('/health', (_req, res) => res.json({ ok: true }));
  return app;
}

test('records templates and outcomes once, with no IDs, queries, or request payloads', async () => {
  const app = testApp();
  await request(app).get('/v1/users/private-person?email=secret@example.com');
  await request(app).get('/v1/posts/secret-post/comments');
  await request(app).get('/unknown-person?token=secret-token');
  const metrics = await performanceRegistry.getMetricsAsJSON();
  const serialized = JSON.stringify(metrics);
  for (const privateValue of ['private-person', 'secret@example.com', 'secret-post', 'unknown-person', 'secret-token']) {
    expect(serialized).not.toContain(privateValue);
  }
  const histogram = performanceRegistry.getSingleMetric('aside_http_duration_seconds') as Histogram<string>;
  const counts = (await histogram.get()).values.filter(v => v.metricName?.endsWith('_count'));
  expect(counts).toEqual(expect.arrayContaining([
    expect.objectContaining({ value: 1, labels: { method: 'GET', route: '/v1/users/:id', outcome: 'ok' } }),
    expect.objectContaining({ value: 1, labels: { method: 'GET', route: '/v1/posts/:id/comments', outcome: 'server_error' } }),
    expect.objectContaining({ value: 1, labels: { method: 'GET', route: 'unmatched', outcome: 'client_error' } }),
  ]));
  expect(counts.reduce((total, v) => total + v.value, 0)).toBe(3);
});

test('does not instrument requests or start listener when disabled', async () => {
  process.env.PERFORMANCE_METRICS = '0';
  await request(testApp()).get('/health');
  expect((await performanceRegistry.getSingleMetric('aside_http_duration_seconds')!.get()).values).toHaveLength(0);
  expect(startPerformanceServer({ totalCount: 0, idleCount: 0, waitingCount: 0 })).toBeUndefined();
  await measureStage('otp_delivery', async () => 42);
  expect((await performanceRegistry.getSingleMetric('aside_operation_stage_seconds')!.get()).values).toHaveLength(0);
});

test('distinguishes rejection before route matching from an unknown route', async () => {
  const app = express().use(measureHttp).use(express.json());
  app.use('/v1/users', (_req, res) => { res.status(401).end(); });
  app.get('/known', () => { throw new AppError(404, 'Missing resource'); });
  app.get('/unsafe-reason', (_req, res) => { res.locals.failureReason = 'private@example.com'; res.status(429).end(); });
  app.use(errorHandler);
  await request(app).get('/v1/users/private-id');
  await request(app).get('/unknown-id?secret=private-value');
  await request(app).get('/known');
  await request(app).get('/unsafe-reason');
  await request(app).post('/v1/auth/request-otp').type('json').send('{"email":"private@example.com"');
  const failures = await performanceRegistry.getSingleMetric('aside_http_failures_total')!.get();
  expect(failures.values).toEqual(expect.arrayContaining([
    expect.objectContaining({ value: 1, labels: { method: 'GET', route: 'unmatched', status: '401', reason: 'auth_failure' } }),
    expect.objectContaining({ value: 1, labels: { method: 'GET', route: 'unmatched', status: '404', reason: 'route_not_found' } }),
    expect.objectContaining({ value: 1, labels: { method: 'GET', route: '/known', status: '404', reason: 'not_found' } }),
    expect.objectContaining({ value: 1, labels: { method: 'GET', route: '/unsafe-reason', status: '429', reason: 'rate_limited' } }),
    expect.objectContaining({ value: 1, labels: { method: 'POST', route: 'unmatched', status: '400', reason: 'malformed_body' } }),
  ]));
  expect(failures.values.reduce((sum, row) => sum + row.value, 0)).toBe(5);
  for (const privateValue of ['private-id', 'unknown-id', 'private-value', 'private@example.com']) {
    expect(JSON.stringify(await performanceRegistry.getMetricsAsJSON())).not.toContain(privateValue);
  }
});

test('records an aborted response once even if finish follows close', async () => {
  const req = { originalUrl: '/unknown-id?token=secret', method: 'CUSTOM' };
  const res = Object.assign(new EventEmitter(), { statusCode: 200, writableFinished: false, locals: {} });
  measureHttp(req as any, res as any, () => {});
  res.emit('close');
  res.emit('finish');
  const failures = await performanceRegistry.getSingleMetric('aside_http_failures_total')!.get();
  expect(failures.values).toEqual([expect.objectContaining({ value: 1,
    labels: { method: 'OTHER', route: 'unmatched', status: 'aborted', reason: 'request_aborted' } })]);
});

test('separates time before the message handler from handler work without changing results', async () => {
  let now = 0n;
  const clock = jest.spyOn(process.hrtime, 'bigint').mockImplementation(() => now);
  try {
    const req = { originalUrl: '/v1/conversations/private-id/messages', method: 'POST' };
    const res = Object.assign(new EventEmitter(), { statusCode: 201, writableFinished: true, locals: {} });
    measureHttp(req as any, res as any, () => {});
    now = 3_000_000_000n;
    const handler = measureMessageHandler(async () => {
      await measureStage('message_persist', async () => { now += 10_000_000n; });
    });
    await handler(req as any, res as any);
    const metric = await (performanceRegistry.getSingleMetric('aside_operation_stage_seconds') as Histogram<string>).get();
    const sums = metric.values.filter(v => v.metricName?.endsWith('_sum'));
    expect(sums).toEqual(expect.arrayContaining([
      expect.objectContaining({ value: 3, labels: { stage: 'message_prehandler', outcome: 'ok' } }),
      expect.objectContaining({ value: 0.01, labels: { stage: 'message_handler', outcome: 'ok' } }),
      expect.objectContaining({ value: 0.01, labels: { stage: 'message_persist', outcome: 'ok' } }),
    ]));
    const failure = new Error('private detail');
    await expect(measureStage('message_fanout', async () => { throw failure; })).rejects.toBe(failure);
    expect(JSON.stringify(await performanceRegistry.getMetricsAsJSON())).not.toContain('private');
  } finally { clock.mockRestore(); }
});

test('serves numeric metrics only on container loopback', async () => {
  const server = startPerformanceServer({ totalCount: 2, idleCount: 1, waitingCount: 0 })!;
  try {
    if (!server.listening) await new Promise<void>(resolve => server.once('listening', resolve));
    expect(server.address()).toEqual(expect.objectContaining({ address: '127.0.0.1', port: 9464 }));
    const response = await request(server).get('/metrics.json').expect(200);
    expect(response.body.version).toBe(1);
    expect(response.body.metrics).toEqual(expect.arrayContaining([expect.objectContaining({ name: 'aside_db_pool_total' })]));
    await request(server).get('/metrics.json?anything=1').expect(404);
  } finally { await new Promise<void>(resolve => server.close(() => resolve())); }
});
