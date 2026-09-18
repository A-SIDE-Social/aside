export interface NewsletterConfig {
  key: string;
  sendingKey: string;
  segmentId: string;
  topicId: string;
  apiUrl: string;
  siteUrl: string;
  from: string;
  replyTo: string;
  postalAddress: string;
  origins: string[];
}

export function newsletterConfig(): NewsletterConfig | null {
  const key = process.env.NEWSLETTER_RESEND_API_KEY;
  const segmentId = process.env.NEWSLETTER_SEGMENT_ID;
  const topicId = process.env.NEWSLETTER_TOPIC_ID;
  const apiUrl = process.env.NEWSLETTER_API_URL?.replace(/\/+$/, '');
  const siteUrl = process.env.PUBLIC_APP_URL?.replace(/\/+$/, '');
  const from = process.env.NEWSLETTER_FROM_EMAIL || process.env.MARKETING_FROM_EMAIL;
  const replyTo = process.env.NEWSLETTER_REPLY_TO_EMAIL || process.env.MARKETING_REPLY_TO_EMAIL;
  const postalAddress = process.env.NEWSLETTER_POSTAL_ADDRESS;
  if (!key || !segmentId || !topicId || !apiUrl || !siteUrl || !from || !replyTo || !postalAddress) return null;
  try {
    for (const value of [apiUrl, siteUrl]) {
      const url = new URL(value);
      if (url.origin !== value || (url.protocol !== 'https:' && process.env.NODE_ENV !== 'test')) return null;
    }
  } catch { return null; }
  return {
    key, segmentId, topicId, apiUrl, siteUrl, from, replyTo, postalAddress,
    sendingKey: process.env.RESEND_API_KEY || key,
    origins: (process.env.NEWSLETTER_ALLOWED_ORIGINS || siteUrl).split(',').map(s => s.trim()),
  };
}
