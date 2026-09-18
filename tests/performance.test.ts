import express from 'express';
import request from 'supertest';
import { Histogram } from '@prometheus-io/client';
import { measureHttp, performanceRegistry, startPerformanceServer } from '../src/performance';

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
