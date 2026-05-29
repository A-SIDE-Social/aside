// ---------------------------------------------------------------------------
// Plan-gated: only feed history changes by subscription tier
// ---------------------------------------------------------------------------

export const PLANS = {
  free: {
    feedHistoryDays: 30,
  },
  paid: {
    feedHistoryDays: null as number | null, // unlimited
  },
} as const;

// ---------------------------------------------------------------------------
// Hard limits (same for all users)
// ---------------------------------------------------------------------------

export const LIMITS = {
  maxPhotosPerPost: 10,
  maxGroups: 10,
  maxVideoStorySeconds: 30,
  maxInvites: 25,
  inviteExpirationDays: 30,
  maxBioLength: 160,
  // 2,200 matches Instagram. Generous enough that voice-dictated captions
  // and the occasional long-form post fit, while still bounded so the feed
  // doesn't degenerate into walls of text.
  maxCaptionLength: 2200,
  maxTextPostLength: 2200,
  maxCommentLength: 1000,
  maxGroupNameLength: 30,
  storyExpirationHours: 24,
  messagesPerPage: 50,
  postsPerPage: 20,
} as const;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export type PlanTier = 'free' | 'paid';

export function getUserPlan(subscriptionStatus: string): PlanTier {
  return subscriptionStatus === 'trial' || subscriptionStatus === 'active'
    ? 'paid'
    : 'free';
}

export function getPlanLimits(subscriptionStatus: string) {
  return PLANS[getUserPlan(subscriptionStatus)];
}

// ---------------------------------------------------------------------------
// System user — sentinel row used to own dev/system-managed records
// (e.g. the seeded dev invite code). Excluded by WHERE filters in
// every user-listing query so it never surfaces in friend lists,
// follower lists, search, etc.
//
// Override via SYSTEM_USER_EMAIL if you already have a sentinel row
// from a previous deployment.
// ---------------------------------------------------------------------------

export const SYSTEM_USER_EMAIL =
  process.env.SYSTEM_USER_EMAIL || 'system@example.com';

// ---------------------------------------------------------------------------
// RevenueCat / Subscription plan metadata
// ---------------------------------------------------------------------------

export const REVENUECAT_ENTITLEMENT = 'pro';
export const FAMILY_MAX_MEMBERS = 6; // owner + 5

// Map RevenueCat product IDs to our plan types
export const PRODUCT_TO_PLAN: Record<string, string> = {
  aside_pro_yearly: 'pro_individual',
  'aside_pro_yearly:annual': 'pro_individual',
  aside_pro_family_yearly: 'pro_family',
  'aside_pro_family_yearly:annual': 'pro_family',
};

// Valid durations for RevenueCat promotional grants
export const PROMO_DURATIONS = [
  'daily', 'three_day', 'weekly', 'monthly', 'two_month',
  'three_month', 'six_month', 'yearly', 'lifetime',
] as const;
