/** Partner codes select native store offers; they never grant entitlements. */
export type PartnerPlan = 'pro_individual' | 'pro_family';
type Price = { currencyCode: string; firstYearMicros: number; renewalMicros: number };
type Plan = {
  iosProductId: string; androidProductId: string; androidBasePlanId: string;
  androidOfferId: string; appleCode: string; prices: Record<string, Price>;
};
export type PartnerCampaign = {
  code: string; name: string; active: boolean; startsAt: string; endsAt: string;
  plans: Partial<Record<PartnerPlan, Plan>>;
};
const planNames = new Set(['pro_individual', 'pro_family']);
const nonempty = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 200;
const validDate = (v: unknown): v is string => typeof v === 'string' && /Z$/.test(v) && Number.isFinite(Date.parse(v));

export function parsePartnerCampaigns(raw: string): PartnerCampaign[] {
  const campaigns = JSON.parse(raw) as PartnerCampaign[];
  if (!Array.isArray(campaigns) || campaigns.length > 100) throw new Error('Invalid partner campaign configuration');
  const seen = new Set<string>();
  for (const c of campaigns) {
    if (!c || typeof c.code !== 'string' || !/^[A-Z0-9]{3,40}$/.test(c.code) || seen.has(c.code) ||
        !nonempty(c.name) || typeof c.active !== 'boolean' ||
        !validDate(c.startsAt) || !validDate(c.endsAt) || Date.parse(c.startsAt) >= Date.parse(c.endsAt) ||
        !c.plans || Array.isArray(c.plans) || typeof c.plans !== 'object' || !Object.keys(c.plans).length) {
      throw new Error('Invalid partner campaign configuration');
    }
    seen.add(c.code);
    for (const [name, p] of Object.entries(c.plans)) {
      if (!planNames.has(name) || !p || !nonempty(p.iosProductId) || !nonempty(p.androidProductId) ||
          typeof p.androidBasePlanId !== 'string' || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(p.androidBasePlanId) ||
          typeof p.androidOfferId !== 'string' || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(p.androidOfferId) ||
          typeof p.appleCode !== 'string' || !/^[A-Z0-9]{3,64}$/.test(p.appleCode) || !p.prices || typeof p.prices !== 'object' || Array.isArray(p.prices) || !Object.keys(p.prices).length) {
        throw new Error('Invalid partner plan configuration');
      }
      for (const [country, price] of Object.entries(p.prices)) {
        if (!/^[A-Z]{2,3}$/.test(country) || !price || !/^[A-Z]{3}$/.test(price.currencyCode) ||
            !Number.isSafeInteger(price.firstYearMicros) || !Number.isSafeInteger(price.renewalMicros) ||
            price.firstYearMicros <= 0 || price.firstYearMicros >= price.renewalMicros) {
          throw new Error('Invalid partner price configuration');
        }
      }
    }
  }
  return campaigns;
}

export function resolvePartnerOffer(campaigns: PartnerCampaign[], input: {
  code: string; platform: 'ios' | 'android'; country: string;
}, appleAppId: string, now = Date.now()) {
  const country = input.country === 'US' ? 'USA' : input.country;
  const campaign = campaigns.find(c => c.code === input.code && c.active &&
    Date.parse(c.startsAt) <= now && now < Date.parse(c.endsAt));
  if (!campaign) return null;
  const plans = Object.entries(campaign.plans).flatMap(([plan, p]) => {
    const price = p!.prices[country];
    if (!price) return [];
    return [{
      plan, ...price,
      productId: input.platform === 'ios' ? p!.iosProductId : p!.androidProductId,
      ...(input.platform === 'ios' ? {
        redemptionUrl: `https://apps.apple.com/redeem?ctx=offercodes&id=${appleAppId}&code=${p!.appleCode}`,
      } : { optionId: `${p!.androidBasePlanId}:${p!.androidOfferId}` }),
    }];
  });
  return plans.length ? {
    code: campaign.code, name: campaign.name, endsAt: campaign.endsAt,
    duration: 'P1Y', eligibility: 'new_subscribers', plans,
  } : null;
}
