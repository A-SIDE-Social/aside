import { createServer } from 'http';
import { Request, Response, RequestHandler } from 'express';
import { collectDefaultMetrics, Counter, Gauge, Histogram, Registry } from '@prometheus-io/client';
import { defaultFailureReason, failureReasons } from './lib/failureReason';

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
const httpFailures = new Counter({ name: 'aside_http_failures_total', help: 'HTTP failures by bounded status and reason',
  labelNames: ['method', 'route', 'status', 'reason'] as const, registers: [performanceRegistry] });
const httpFailureContexts = new Counter({
  name: 'aside_http_failure_contexts_total',
  help: 'HTTP failures by bounded request context; never includes raw paths, headers, or identifiers',
  labelNames: ['method', 'path_class', 'client_platform', 'auth_present', 'abort_phase', 'status', 'reason'] as const,
  registers: [performanceRegistry],
});
const stageDuration = new Histogram({ name: 'aside_operation_stage_seconds', help: 'Duration of fixed application stages',
  labelNames: ['stage', 'outcome'] as const, buckets, registers: [performanceRegistry] });
export const performanceStages = ['otp_delivery', 'message_prehandler', 'message_handler', 'message_persist', 'message_fanout'] as const;
type PerformanceStage = typeof performanceStages[number];
const requestStarts = new WeakMap<Request, bigint>();

// Only these literal mount prefixes and Express's declared route templates can
// become labels. Never use baseUrl (it may include IDs), params or original URLs.
const prefixes = ['/v1/auth', '/v1/users', '/v1/follows', '/v1/invites', '/v1/invite-link', '/v1/feed', '/v1/posts',
  '/v1/stories', '/v1/conversations', '/v1/lists', '/v1/groups', '/v1/devices', '/v1/dm-attachments',
  '/v1/contacts', '/v1/subscriptions', '/v1/webhooks', '/v1/partner-offers', '/newsletter', '/admin', '/unsubscribe'];
const methods = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']);
export const failurePathClasses = [
  'auth', 'users', 'follows', 'invites', 'invite_link', 'feed', 'posts', 'comments', 'stories',
  'conversations', 'lists', 'groups_legacy', 'devices', 'dm_attachments', 'contacts', 'subscriptions',
  'webhooks', 'partner_offers', 'newsletter', 'admin', 'unsubscribe', 'health', 'docs', 'well_known',
  'api_other', 'root', 'other',
] as const;
type FailurePathClass = typeof failurePathClasses[number];
const pathClassPrefixes: ReadonlyArray<readonly [string, FailurePathClass]> = [
  ['/v1/auth', 'auth'], ['/v1/users', 'users'], ['/v1/follows', 'follows'], ['/v1/invites', 'invites'],
  ['/v1/invite-link', 'invite_link'], ['/v1/feed', 'feed'], ['/v1/posts', 'posts'], ['/v1/comments', 'comments'],
  ['/v1/stories', 'stories'], ['/v1/conversations', 'conversations'], ['/v1/lists', 'lists'],
  ['/v1/groups', 'groups_legacy'], ['/v1/devices', 'devices'], ['/v1/dm-attachments', 'dm_attachments'],
  ['/v1/contacts', 'contacts'], ['/v1/subscriptions', 'subscriptions'], ['/v1/webhooks', 'webhooks'],
  ['/v1/partner-offers', 'partner_offers'], ['/newsletter', 'newsletter'], ['/admin', 'admin'],
  ['/unsubscribe', 'unsubscribe'],
];
export const failureClientPlatforms = ['ios', 'android', 'web', 'other', 'unknown'] as const;
type FailureClientPlatform = typeof failureClientPlatforms[number];

function boundedPathClass(pathname: string): FailurePathClass {
  const match = pathClassPrefixes.find(([prefix]) => pathname === prefix || pathname.startsWith(prefix + '/'));
  if (match) return match[1];
  if (pathname === '/health') return 'health';
  if (pathname === '/openapi.json' || pathname === '/docs' || pathname.startsWith('/docs/')) return 'docs';
  if (pathname.startsWith('/.well-known/')) return 'well_known';
  if (pathname === '/v1' || pathname.startsWith('/v1/')) return 'api_other';
  if (pathname === '/') return 'root';
  return 'other';
}

function boundedClientPlatform(req: Request): FailureClientPlatform {
  const value = req.headers['x-a-side-client-platform'];
  return typeof value === 'string' && failureClientPlatforms.includes(value as FailureClientPlatform) && value !== 'unknown'
    ? value as FailureClientPlatform : 'unknown';
}

export function failureContext(req: Request, aborted: boolean) {
  const pathname = req.originalUrl.split('?')[0];
  return {
    path_class: boundedPathClass(pathname),
    client_platform: boundedClientPlatform(req),
    auth_present: typeof req.headers.authorization === 'string' && req.headers.authorization.length > 0 ? 'yes' : 'no',
    abort_phase: aborted ? (req.complete ? 'response' : 'request') : 'not_aborted',
  } as const;
}
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
  requestStarts.set(req, start);
  let recorded = false;
  const record = (aborted: boolean) => {
    if (recorded) return;
    recorded = true;
    try {
      const method = methods.has(req.method) ? req.method : 'OTHER';
      const route = routeLabel(req, prefix);
      httpDuration.observe({ method, route,
        outcome: aborted ? 'aborted' : res.statusCode >= 500 ? 'server_error' : res.statusCode >= 400 ? 'client_error' : 'ok' },
      Number(process.hrtime.bigint() - start) / 1e9);
      if (aborted || res.statusCode >= 400) {
        const explicitReason = res.locals.failureReason;
        const reason = aborted ? 'request_aborted' : failureReasons.includes(explicitReason)
          ? explicitReason : defaultFailureReason(res.statusCode, route !== 'unmatched');
        httpFailures.inc({ method, route, status: aborted ? 'aborted' : String(res.statusCode), reason });
        httpFailureContexts.inc({ method, ...failureContext(req, aborted),
          status: aborted ? 'aborted' : String(res.statusCode), reason });
      }
    } catch { missed.inc(); }
  };
  res.once('finish', () => record(false));
  res.once('close', () => record(!res.writableFinished));
  next();
};

function recordStage(stage: PerformanceStage, start: bigint, ok: boolean) {
  try { stageDuration.observe({ stage, outcome: ok ? 'ok' : 'error' }, Number(process.hrtime.bigint() - start) / 1e9); }
  catch { missed.inc(); }
}

// Includes body transfer/parsing, authentication and rate-limit middleware.
// It is recorded only once a send reaches its handler, with no request values.
export function recordMessagePrehandler(req: Request) {
  const start = requestStarts.get(req);
  if (start !== undefined) {
    requestStarts.delete(req);
    recordStage('message_prehandler', start, true);
  }
}

export function measureMessageHandler(handler: (req: Request, res: Response) => Promise<void>) {
  return (req: Request, res: Response) => {
    recordMessagePrehandler(req);
    return measureStage('message_handler', () => handler(req, res));
  };
}

export async function measureStage<T>(stage: PerformanceStage, work: () => Promise<T>): Promise<T> {
  if (!performanceEnabled()) return work();
  const start = process.hrtime.bigint();
  try {
    const result = await work();
    recordStage(stage, start, true);
    return result;
  } catch (error) { recordStage(stage, start, false); throw error; }
}

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
