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
const httpFailureInvestigations = new Counter({
  name: 'aside_http_failure_investigations_total',
  help: 'HTTP failures by privacy-bounded routing, client, auth, body, and lifecycle evidence',
  labelNames: [
    'method', 'path_class', 'endpoint', 'route_state', 'client_platform', 'client_generation',
    'request_attempt', 'auth_kind', 'auth_result', 'body_kind', 'failure_stage', 'abort_phase',
    'status', 'reason',
  ] as const,
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
export const failureEndpoints = [
  'auth_request_otp', 'auth_verify_otp', 'auth_refresh', 'auth_session', 'auth_other',
  'users_me', 'users_feed_seen', 'users_member', 'users_other', 'feed_root', 'feed_other',
  'devices_token', 'devices_keys_upload', 'devices_keys_replenish', 'devices_keys_rotate_signed',
  'devices_revoke', 'devices_other', 'root', 'well_known', 'family_other', 'other',
] as const;
type FailureEndpoint = typeof failureEndpoints[number];
export const failureRouteStates = ['matched', 'declared_method', 'method_mismatch', 'unknown_path'] as const;
type FailureRouteState = typeof failureRouteStates[number];
const failureClientGenerations = ['context_v2', 'platform_only', 'absent', 'invalid'] as const;
const failureRequestAttempts = ['initial', 'auth_retry', 'unknown', 'invalid'] as const;
const failureAuthKinds = ['missing', 'bearer', 'other'] as const;
export const failureAuthResults = [
  'not_checked', 'missing_or_malformed', 'invalid_or_expired', 'inactive_account', 'accepted',
] as const;
export type FailureAuthResult = typeof failureAuthResults[number];
const failureBodyKinds = ['none', 'json', 'form', 'multipart', 'binary', 'untyped', 'other'] as const;
export const failureStages = ['routing', 'body', 'auth', 'handler', 'pre_route', 'aborted_request', 'aborted_response'] as const;
export type FailureStage = typeof failureStages[number];

type EndpointRule = readonly [RegExp, FailureEndpoint, readonly string[]];
const endpointRules: readonly EndpointRule[] = [
  [/^\/v1\/auth\/request-otp\/?$/, 'auth_request_otp', ['POST']],
  [/^\/v1\/auth\/verify-otp\/?$/, 'auth_verify_otp', ['POST']],
  [/^\/v1\/auth\/refresh\/?$/, 'auth_refresh', ['POST']],
  [/^\/v1\/auth\/session\/?$/, 'auth_session', ['DELETE']],
  [/^\/v1\/users\/me\/?$/, 'users_me', ['GET', 'PATCH', 'DELETE']],
  [/^\/v1\/users\/me\/feed-seen\/?$/, 'users_feed_seen', ['POST']],
  [/^\/v1\/users\/[^/]+\/?$/, 'users_member', ['GET']],
  [/^\/v1\/feed\/?$/, 'feed_root', ['GET']],
  [/^\/v1\/devices\/token\/?$/, 'devices_token', ['POST', 'DELETE']],
  [/^\/v1\/devices\/keys\/upload\/?$/, 'devices_keys_upload', ['POST']],
  [/^\/v1\/devices\/keys\/replenish\/?$/, 'devices_keys_replenish', ['POST']],
  [/^\/v1\/devices\/keys\/rotate-signed\/?$/, 'devices_keys_rotate_signed', ['POST']],
  [/^\/v1\/devices\/revoke\/?$/, 'devices_revoke', ['POST']],
];

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

function boundedEndpoint(pathname: string, method: string): { endpoint: FailureEndpoint; route_state: FailureRouteState } {
  const rule = endpointRules.find(([pattern]) => pattern.test(pathname));
  if (rule) return { endpoint: rule[1], route_state: rule[2].includes(method) ? 'declared_method' : 'method_mismatch' };
  const pathClass = boundedPathClass(pathname);
  const endpoint: FailureEndpoint = pathClass === 'auth' ? 'auth_other'
    : pathClass === 'users' ? 'users_other'
    : pathClass === 'feed' ? 'feed_other'
    : pathClass === 'devices' ? 'devices_other'
    : pathClass === 'root' ? 'root'
    : pathClass === 'well_known' ? 'well_known'
    : pathClass === 'other' ? 'other' : 'family_other';
  return { endpoint, route_state: 'unknown_path' };
}

function boundedClientGeneration(req: Request) {
  const generation = req.headers['x-a-side-client-generation'];
  const platform = boundedClientPlatform(req);
  if (generation === '2' && platform !== 'unknown') return 'context_v2' as const;
  if (generation === undefined && platform !== 'unknown') return 'platform_only' as const;
  if (generation === undefined) return 'absent' as const;
  return 'invalid' as const;
}

function boundedRequestAttempt(req: Request) {
  const value = req.headers['x-a-side-request-attempt'];
  if (value === undefined) return 'unknown' as const;
  if ((failureRequestAttempts as readonly string[]).includes(String(value)) && value !== 'unknown' && value !== 'invalid') {
    return value as 'initial' | 'auth_retry';
  }
  return 'invalid' as const;
}

function boundedAuthKind(req: Request) {
  const value = req.headers.authorization;
  if (typeof value !== 'string' || value.length === 0) return 'missing' as const;
  return value.startsWith('Bearer ') ? 'bearer' as const : 'other' as const;
}

function boundedBodyKind(req: Request) {
  const contentType = req.headers['content-type'];
  const length = req.headers['content-length'];
  const transfer = req.headers['transfer-encoding'];
  if (contentType === undefined) return length === undefined && transfer === undefined ? 'none' as const : 'untyped' as const;
  const value = Array.isArray(contentType) ? contentType[0] : contentType;
  const mediaType = value.toLowerCase().split(';', 1)[0].trim();
  if (mediaType === 'application/json' || mediaType.endsWith('+json')) return 'json' as const;
  if (mediaType === 'application/x-www-form-urlencoded') return 'form' as const;
  if (mediaType === 'multipart/form-data') return 'multipart' as const;
  if (mediaType === 'application/octet-stream' || mediaType.startsWith('image/') || mediaType.startsWith('video/')) return 'binary' as const;
  return 'other' as const;
}

function boundedFailureStage(req: Request, res: Response, aborted: boolean, routeState: FailureRouteState): FailureStage {
  if (aborted) return req.complete ? 'aborted_response' : 'aborted_request';
  const explicit = res.locals.failureStage;
  if ((failureStages as readonly unknown[]).includes(explicit)) return explicit as FailureStage;
  if (typeof req.route?.path === 'string') return 'handler';
  if (routeState === 'unknown_path' || routeState === 'method_mismatch') return 'routing';
  return 'pre_route';
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

export function failureInvestigation(req: Request, res: Response, aborted: boolean) {
  const pathname = req.originalUrl.split('?')[0];
  const method = methods.has(req.method) ? req.method : 'OTHER';
  const endpoint = boundedEndpoint(pathname, method);
  const matched = typeof req.route?.path === 'string';
  const routeState: FailureRouteState = matched ? 'matched' : endpoint.route_state;
  const authResult = failureAuthResults.includes(res.locals.authResult) ? res.locals.authResult as FailureAuthResult : 'not_checked';
  return {
    method,
    path_class: boundedPathClass(pathname),
    endpoint: endpoint.endpoint,
    route_state: routeState,
    client_platform: boundedClientPlatform(req),
    client_generation: boundedClientGeneration(req),
    request_attempt: boundedRequestAttempt(req),
    auth_kind: boundedAuthKind(req),
    auth_result: authResult,
    body_kind: boundedBodyKind(req),
    failure_stage: boundedFailureStage(req, res, aborted, routeState),
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
        httpFailureInvestigations.inc({ ...failureInvestigation(req, res, aborted),
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
