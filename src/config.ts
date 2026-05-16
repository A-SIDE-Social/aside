function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '');
}

function envList(name: string, fallback: string[] = []): string[] {
  const raw = process.env[name];
  if (!raw) return fallback;
  return raw
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

function hostnameFromUrl(value: string): string | null {
  try {
    return new URL(value).hostname.toLowerCase();
  } catch {
    return null;
  }
}

const publicAppUrl = stripTrailingSlash(
  process.env.PUBLIC_APP_URL || 'http://localhost:3000',
);
const inviteLinkHost = stripTrailingSlash(
  process.env.INVITE_LINK_HOST || publicAppUrl,
);
const inviteLinkHostName = hostnameFromUrl(inviteLinkHost);

export const config = {
  port: parseInt(process.env.PORT || '3000', 10),
  databaseUrl: process.env.DATABASE_URL || 'postgres://aside:aside_dev_password@localhost:5433/aside',
  jwtSecret: process.env.JWT_SECRET || 'dev-secret',
  jwtRefreshSecret: process.env.JWT_REFRESH_SECRET || 'dev-refresh-secret',
  jwtExpiresIn: '1y',
  refreshTokenExpiresIn: '1y',
  s3Region: process.env.S3_REGION || process.env.AWS_REGION || 'us-east-1',
  s3Bucket: process.env.S3_BUCKET || 'aside-media-dev',
  s3Endpoint: process.env.S3_ENDPOINT || '',  // e.g. https://nyc3.digitaloceanspaces.com
  s3AccessKey: process.env.S3_ACCESS_KEY || process.env.AWS_ACCESS_KEY_ID || '',
  s3SecretKey: process.env.S3_SECRET_KEY || process.env.AWS_SECRET_ACCESS_KEY || '',
  cdnUrl: process.env.CDN_URL || process.env.CLOUDFRONT_URL || '',  // e.g. https://media.example.com or https://bucket.nyc3.cdn.digitaloceanspaces.com
  nodeEnv: process.env.NODE_ENV || 'development',
  devOtp: process.env.DEV_OTP || '',  // Fixed OTP code. In dev/test it applies to every email; in production it ONLY applies to emails in devOtpAllowedEmails (must be set, otherwise DEV_OTP is ignored in prod).
  devOtpAllowedEmails: (process.env.DEV_OTP_ALLOWED_EMAILS || '')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean),
  postmarkApiToken: process.env.POSTMARK_API_TOKEN || '',
  otpFromEmail: process.env.OTP_FROM_EMAIL || 'noreply@example.com',
  firebaseServiceAccountPath: process.env.FIREBASE_SERVICE_ACCOUNT_PATH || '',
  revenuecatWebhookSecret: process.env.REVENUECAT_WEBHOOK_SECRET || '',
  revenuecatApiKey: process.env.REVENUECAT_API_KEY || '',
  adminUserIds: (process.env.ADMIN_USER_IDS || '').split(',').filter(Boolean),
  publicAppUrl,
  inviteLinkHost,
  inviteLinkAllowedHosts: envList(
    'INVITE_LINK_ALLOWED_HOSTS',
    inviteLinkHostName ? [inviteLinkHostName] : [],
  ),
  supportEmail: process.env.SUPPORT_EMAIL || 'support@example.com',
  legalTermsUrl: process.env.LEGAL_TERMS_URL || `${publicAppUrl}/terms`,
  legalPrivacyUrl: process.env.LEGAL_PRIVACY_URL || `${publicAppUrl}/privacy`,
  // Discord webhook URL for operator-side new-user notifications.
  // Set on the prod env to enable; if unset, the notify call is a
  // no-op (fail-quiet — registration must never depend on Discord
  // being reachable).
  discordNewUserWebhookUrl: process.env.DISCORD_NEW_USER_WEBHOOK_URL || '',
  // Resend API key for marketing broadcasts (separate from Postmark
  // which handles transactional OTP). Empty in dev/test; the admin
  // /admin/broadcast page surfaces an explicit "no API key" message
  // when unset rather than silently no-op'ing.
  resendApiKey: process.env.RESEND_API_KEY || '',
  // From address for broadcasts. Should be on a verified sending
  // domain owned by the operator.
  marketingFromEmail:
    process.env.MARKETING_FROM_EMAIL || 'broadcasts@example.com',
  // Reply-to header for broadcasts so users can hit reply and reach
  // a real inbox.
  marketingReplyToEmail:
    process.env.MARKETING_REPLY_TO_EMAIL || process.env.SUPPORT_EMAIL || 'support@example.com',
  // Public-facing URL for the unsubscribe page. The signed token
  // gets appended as ?token=...
  unsubscribeBaseUrl:
    process.env.UNSUBSCRIBE_BASE_URL || `${publicAppUrl}/unsubscribe`,
  // Public-facing URL where the marketing site or App Store-link
  // CTAs in broadcast emails point to. Used inside templates so we
  // can swap to a campaign-tracked link later without code changes.
  marketingCtaUrl:
    process.env.MARKETING_CTA_URL || publicAppUrl,
};
