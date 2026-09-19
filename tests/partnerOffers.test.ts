import express from 'express';
import request from 'supertest';
import { parsePartnerCampaigns, resolvePartnerOffer } from '../src/services/partnerOffers';
import { config } from '../src/config';
import router from '../src/routes/partnerOffers';
const plan = {
  iosProductId: 'individual', androidProductId: 'individual', androidBasePlanId: 'annual',
  androidOfferId: 'partner-year', appleCode: 'EXAMPLEIND',
  prices: { USA: { currencyCode: 'USD', firstYearMicros: 15000000, renewalMicros: 20000000 } },
};
const campaign = {
  code: 'EXAMPLE', name: 'Example readers', active: true,
  startsAt: '2026-09-01T00:00:00Z', endsAt: '2026-12-01T00:00:00Z',
  plans: { pro_individual: plan },
};
const now = Date.parse('2026-09-18T00:00:00Z');
const input = { code: 'EXAMPLE', platform: 'android' as const, country: 'US' };
const campaigns = () => parsePartnerCampaigns(JSON.stringify([campaign]));

test('resolves only exact native plan and advertised prices', () => {
  expect(resolvePartnerOffer(campaigns(), input, '123', now)?.plans[0]).toEqual({
    plan: 'pro_individual', ...plan.prices.USA, productId: 'individual', optionId: 'annual:partner-year',
  });
  const ios = resolvePartnerOffer(campaigns(), { ...input, platform: 'ios' }, '123', now)!;
  expect(ios.plans[0]).toHaveProperty('redemptionUrl', 'https://apps.apple.com/redeem?ctx=offercodes&id=123&code=EXAMPLEIND');
  expect(ios.plans[0]).not.toHaveProperty('optionId');
});

test('disabled, future, expired, unknown and unsupported-market offers fail closed', () => {
  for (const patch of [{ active: false }, { startsAt: '2026-10-01T00:00:00Z' }, { endsAt: '2026-09-18T00:00:00Z' }]) {
    const cs = parsePartnerCampaigns(JSON.stringify([{ ...campaign, ...patch }]));
    expect(resolvePartnerOffer(cs, input, '123', now)).toBeNull();
  }
  expect(resolvePartnerOffer(campaigns(), { ...input, code: 'OTHER' }, '123', now)).toBeNull();
  expect(resolvePartnerOffer(campaigns(), { ...input, country: 'GBR' }, '123', now)).toBeNull();
});

test('rejects duplicate codes, bad dates and invalid or non-discounted prices', () => {
  expect(() => parsePartnerCampaigns(JSON.stringify([campaign, campaign]))).toThrow();
  expect(() => parsePartnerCampaigns(JSON.stringify([{ ...campaign, endsAt: 'bad' }]))).toThrow();
  for (const amount of [-1, 0, 20000000, 30000000, 1.5]) {
    const c = { ...campaign, plans: { pro_individual: { ...plan, prices: { USA: { ...plan.prices.USA, firstYearMicros: amount } } } } };
    expect(() => parsePartnerCampaigns(JSON.stringify([c]))).toThrow();
  }
});

const app = express().use(express.json()).use('/offers', router);
test('HTTP validation rejects objects and unsupported platforms without leaking configuration', async () => {
  const result = await request(app).post('/offers/resolve').send({ code: {}, platform: 'web', country: 'US' });
  expect(result.status).toBe(400);
  expect(result.headers['cache-control']).toBe('no-store');
});
test('empty configuration returns an unavailable result', async () => {
  config.partnerCampaigns = [];
  const result = await request(app).post('/offers/resolve').send({ code: 'EXAMPLE', platform: 'ios', country: 'USA' });
  expect(result.status).toBe(404);
  expect(result.body.offer).toBeUndefined();
});

test('HTTP resolution normalizes input and returns only active public terms', async () => {
  config.partnerCampaigns = campaigns();
  const clock = jest.spyOn(Date, 'now').mockReturnValue(now);
  try {
    const result = await request(app).post('/offers/resolve').send({ code: ' example ', platform: 'android', country: 'us' });
    expect(result.status).toBe(200);
    expect(result.body.offer.code).toBe('EXAMPLE');
    expect(result.body.offer.plans[0].optionId).toBe('annual:partner-year');
    expect(result.body.offer.plans[0].appleCode).toBeUndefined();
    expect(result.headers['cache-control']).toBe('no-store');
  } finally { clock.mockRestore(); config.partnerCampaigns = []; }
});
