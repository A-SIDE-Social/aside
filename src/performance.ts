import { createServer } from 'http';
import { Request, RequestHandler } from 'express';
import { collectDefaultMetrics, Counter, Gauge, Histogram, Registry } from '@prometheus-io/client';

export const performanceEnabled = () => process.env.PERFORMANCE_METRICS === '1';
export const performanceRegistry = new Registry();
const startedAt = Date.now() / 1000;
const buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30];
const httpDuration = new Histogram({ name: 'aside_http_duration_seconds', help: 'Completed or aborted HTTP request duration',
  labelNames: ['method', 'route', 'outcome'] as const, buckets, registers: [performanceRegistry] });
const poolWait = new Histogram({ name: 'aside_db_pool_wait_seconds', help: 'Time acquiring a database connection',
  labelNames: ['outcome'] as const, buckets, registers: [performanceRegistry] });
const queryDuration = new Histogram({ name: 'aside_db_query_seconds', help: 'Query helper duration including pool acquisition; no SQL labels',
  labelNames: ['outcome'] as const, buckets, registers: [performanceRegistry] });
export const socketConnections = new Gauge({ name: 'aside_websocket_connections', help: 'Authenticated Socket.IO connections', registers: [performanceRegistry] });
const missed = new Counter({ name: 'aside_metrics_recording_errors_total', help: 'Metric recording failures', registers: [performanceRegistry] });

// Only these literal mount prefixes and Express's declared route templates can
// become labels. Never use baseUrl (it may include IDs), params or original URLs.
const prefixes = ['/v1/auth', '/v1/users', '/v1/follows', '/v1/invites', '/v1/invite-link', '/v1/feed', '/v1/posts',
  '/v1/stories', '/v1/conversations', '/v1/lists', '/v1/groups', '/v1/devices', '/v1/dm-attachments',
  '/v1/contacts', '/v1/subscriptions', '/v1/webhooks', '/newsletter', '/admin', '/unsubscribe'];
const methods = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']);
export function routeLabel(req: Request, prefix: string): string {
  const template: unknown = req.route?.path;
  if (typeof template !== 'string') return 'unmatched';
  // Comments/reactions are declared on the /v1 router with the full template.
  if (prefix.startsWith('/v1') && /^\/(posts|comments)\//.test(template)) return '/v1' + template;
  return prefix + template;
}
export const measureHttp: RequestHandler = (req, res, next) => {
  if (!performanceEnabled()) { next(); return; }
  const pathname = req.originalUrl.split('?')[0];
  const prefix = prefixes.find(p => pathname === p || pathname.startsWith(p + '/')) || (pathname.startsWith('/v1/') ? '/v1' : '');
  const start = process.hrtime.bigint();
  let recorded = false;
  const record = (aborted: boolean) => {
    if (recorded) return;
    recorded = true;
    try {
      httpDuration.observe({ method: methods.has(req.method) ? req.method : 'OTHER', route: routeLabel(req, prefix),
        outcome: aborted ? 'aborted' : res.statusCode >= 500 ? 'server_error' : res.statusCode >= 400 ? 'client_error' : 'ok' },
      Number(process.hrtime.bigint() - start) / 1e9);
    } catch { missed.inc(); }
  };
  res.once('finish', () => record(false));
  res.once('close', () => record(!res.writableFinished));
  next();
};

export function measureDb(kind: 'pool' | 'query') {
  if (!performanceEnabled()) return (_ok: boolean) => {};
  const start = process.hrtime.bigint();
  return (ok: boolean) => {
    try { (kind === 'pool' ? poolWait : queryDuration).observe({ outcome: ok ? 'ok' : 'error' }, Number(process.hrtime.bigint() - start) / 1e9); }
    catch { missed.inc(); }
  };
}

export function startPerformanceServer(pool: { totalCount: number; idleCount: number; waitingCount: number }) {
  if (!performanceEnabled()) return;
  collectDefaultMetrics({ register: performanceRegistry, eventLoopMonitoringPrecision: 20 });
  for (const [name, field] of [['total', 'totalCount'], ['idle', 'idleCount'], ['waiting', 'waitingCount']] as const) {
    new Gauge({ name: `aside_db_pool_${name}`, help: `Database pool ${name}`, registers: [performanceRegistry],
      collect() { this.set(pool[field]); } });
  }
  const server = createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    if (req.method !== 'GET' || !['/metrics', '/metrics.json'].includes(req.url || '')) { res.writeHead(404).end(); return; }
    try {
      if (req.url === '/metrics.json') {
        res.setHeader('Content-Type', 'application/json');
        res.end(JSON.stringify({ version: 1, started_at: startedAt, metrics: await performanceRegistry.getMetricsAsJSON() }));
      } else {
        res.setHeader('Content-Type', performanceRegistry.contentType);
        res.end(await performanceRegistry.metrics());
      }
    } catch { res.writeHead(503).end(); }
  });
  // Inside the container only. No Docker port publication or reverse-proxy route.
  server.listen(9464, '127.0.0.1');
  server.on('error', () => console.warn('Private performance metrics listener unavailable'));
  server.unref();
  return server;
}
