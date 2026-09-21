import express from 'express';
import request from 'supertest';
import { ServerClient } from 'postmark';
import { config } from '../src/config';
import { sendOtpEmail } from '../src/email';
import { errorHandler } from '../src/middleware/errorHandler';
import { measureHttp, performanceRegistry } from '../src/performance';

const mockSendEmail = jest.fn();
jest.mock('postmark', () => ({ ServerClient: jest.fn().mockImplementation(() => ({ sendEmail: mockSendEmail })) }));
const originalEnv = config.nodeEnv;
const originalToken = config.postmarkApiToken;
const originalMetrics = process.env.PERFORMANCE_METRICS;
const app = express().use(measureHttp).post('/send', async (_req, res) => {
  await sendOtpEmail('private@example.com', '987654');
  res.sendStatus(204);
}).use(errorHandler);

beforeEach(() => {
  jest.clearAllMocks();
  mockSendEmail.mockReset().mockResolvedValue({ ErrorCode: 0 });
  config.nodeEnv = 'production';
  config.postmarkApiToken = 'test-token';
  process.env.PERFORMANCE_METRICS = '1';
  performanceRegistry.resetMetrics();
});
afterAll(() => {
  config.nodeEnv = originalEnv;
  config.postmarkApiToken = originalToken;
  if (originalMetrics === undefined) delete process.env.PERFORMANCE_METRICS;
  else process.env.PERFORMANCE_METRICS = originalMetrics;
});

test('sends once with a bounded SDK timeout and records delivery time', async () => {
  await request(app).post('/send').expect(204);
  expect(ServerClient).toHaveBeenCalledWith('test-token', { timeout: 10 });
  expect(mockSendEmail).toHaveBeenCalledTimes(1);
  const metric = await performanceRegistry.getSingleMetric('aside_operation_stage_seconds')!.get();
  expect(metric.values).toContainEqual(expect.objectContaining({ value: 1, labels: { stage: 'otp_delivery', outcome: 'ok' }, metricName: 'aside_operation_stage_seconds_count' }));
});

test.each([
  [401, 10, 503, 'email_auth_failure'],
  [422, 406, 422, 'email_recipient_rejected'],
  [422, 300, 503, 'email_request_rejected'],
  [429, 0, 503, 'email_rate_limited'],
  [500, 101, 503, 'email_provider_unavailable'],
  [503, 100, 503, 'email_provider_unavailable'],
  [0, 0, 503, 'email_provider_unavailable'],
])('classifies provider status %i/code %i without exposing recipient or provider details', async (statusCode, code, expected, reason) => {
  mockSendEmail.mockRejectedValue(Object.assign(new Error('private@example.com: token=test-token code=987654'), {
    statusCode, code, recipients: ['private@example.com'],
  }));
  const log = jest.spyOn(console, 'error').mockImplementation(() => {});
  const warning = jest.spyOn(console, 'warn').mockImplementation(() => {});
  try {
    const response = await request(app).post('/send');
    expect(response.status).toBe(expected);
    expect(mockSendEmail).toHaveBeenCalledTimes(1);
    expect(log).not.toHaveBeenCalled();
    expect(warning).toHaveBeenCalledWith('[OTP] Email delivery failed', { reason });
    const metrics = await performanceRegistry.getMetricsAsJSON();
    for (const secret of ['private@example.com', 'test-token', '987654']) {
      expect(response.text + JSON.stringify(metrics) + JSON.stringify(warning.mock.calls)).not.toContain(secret);
    }
    const failure = await performanceRegistry.getSingleMetric('aside_http_failures_total')!.get();
    expect(failure.values).toContainEqual(expect.objectContaining({ value: 1, labels: { method: 'POST', route: '/send', status: String(expected), reason } }));
    const stage = await performanceRegistry.getSingleMetric('aside_operation_stage_seconds')!.get();
    expect(stage.values).toContainEqual(expect.objectContaining({ metricName: 'aside_operation_stage_seconds_count', value: 1, labels: { stage: 'otp_delivery', outcome: 'error' } }));
  } finally { log.mockRestore(); warning.mockRestore(); }
});

test('missing production configuration fails without logging the OTP or reporting success', async () => {
  config.postmarkApiToken = '';
  const log = jest.spyOn(console, 'log').mockImplementation(() => {});
  const warning = jest.spyOn(console, 'warn').mockImplementation(() => {});
  try {
    await expect(sendOtpEmail('private@example.com', '987654')).rejects.toMatchObject({ statusCode: 503, reason: 'email_not_configured' });
    expect(log).not.toHaveBeenCalled();
    expect(ServerClient).not.toHaveBeenCalled();
    expect(warning).toHaveBeenCalledWith('[OTP] Email delivery unavailable', { reason: 'email_not_configured' });
  } finally { log.mockRestore(); warning.mockRestore(); }
});

test('development still uses the local OTP flow without making a provider request', async () => {
  config.nodeEnv = 'development';
  const log = jest.spyOn(console, 'log').mockImplementation(() => {});
  try {
    await sendOtpEmail('private@example.com', '987654');
    expect(ServerClient).not.toHaveBeenCalled();
    expect(log).toHaveBeenCalledTimes(1);
  } finally { log.mockRestore(); }
});
