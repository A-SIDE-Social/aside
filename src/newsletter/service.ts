import { createHash, randomBytes } from 'crypto';
import { getClient, query } from '../db/pool';
import { NewsletterConfig } from './config';
import { activateSubscriber, resendRequest } from './resend';

export const CONSENT_VERSION = 'notes-2026-09-18';
export const hashToken = (token: string) => createHash('sha256').update(token).digest('hex');
export const validToken = (token: unknown): token is string => typeof token === 'string' && /^[a-f0-9]{64}$/.test(token);
export const escapeHtml = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export function normalizeEmail(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const email = value.trim().toLowerCase();
  if (email.length > 254 || !/^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/.test(email)) return null;
  const local = email.slice(0, email.indexOf('@'));
  if (local.length > 64 || local.startsWith('.') || local.endsWith('.') || local.includes('..')) return null;
  return email;
}

export async function cleanupPendingSignups(): Promise<void> {
  await query("DELETE FROM newsletter_signups WHERE confirmed_at IS NULL AND requested_at < now() - interval '7 days'");
}

export async function requestSignup(email: string, settings: NewsletterConfig): Promise<void> {
  // No IP or app-user identifier is retained in this consent table.
  await cleanupPendingSignups();
  const token = randomBytes(32).toString('hex');
  const digest = hashToken(token);
  const { rows } = await query(
    `INSERT INTO newsletter_signups (email, token_hash, expires_at, consent_version, source)
     VALUES ($1, $2, now() + interval '24 hours', $3, 'website-notes')
     ON CONFLICT (email) DO UPDATE SET
       token_hash = EXCLUDED.token_hash, expires_at = EXCLUDED.expires_at,
       requested_at = now(), completed_at = NULL,
       consent_version = EXCLUDED.consent_version, source = EXCLUDED.source,
       window_started_at = CASE WHEN newsletter_signups.window_started_at < now() - interval '1 day' THEN now() ELSE newsletter_signups.window_started_at END,
       request_count = CASE WHEN newsletter_signups.window_started_at < now() - interval '1 day' THEN 1 ELSE newsletter_signups.request_count + 1 END
     WHERE newsletter_signups.requested_at < now() - interval '15 minutes'
       AND (newsletter_signups.window_started_at < now() - interval '1 day' OR newsletter_signups.request_count < 3)
     RETURNING email`,
    [email, digest, CONSENT_VERSION],
  );
  // Same response for an existing subscription, an unknown address or cooldown.
  if (!rows.length) return;
  const link = `${settings.apiUrl}/newsletter/confirm?token=${token}`;
  const text = `Confirm your A/SIDE Notes subscription\n\nOne short, occasional email about privacy, security and having more control over your digital life.\n\nConfirm here: ${link}\n\nThis link expires in 24 hours. If you didn't request this, ignore this email. You won't be subscribed.\n\n—Adeel\n\n${settings.postalAddress}`;
  const html = `<html lang="en"><body style="font:16px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;max-width:560px;margin:32px auto;padding:0 20px"><h1 style="font-size:24px">Confirm your A/SIDE Notes subscription</h1><p>One short, occasional email about privacy, security and having more control over your digital life.</p><p><a href="${escapeHtml(link)}">Confirm my subscription</a></p><p>This link expires in 24 hours. If you didn't request this, ignore this email. You won't be subscribed.</p><p>—Adeel</p><p style="font-size:12px">${escapeHtml(settings.postalAddress).replace(/\n/g, '<br>')}</p></body></html>`;
  await resendRequest(settings.sendingKey, '/emails', 'POST', {
    from: settings.from, reply_to: settings.replyTo, to: [email],
    subject: 'Confirm your A/SIDE Notes subscription', html, text,
  }, `notes-confirm-${digest}`);
}

export async function confirmSignup(token: string, settings: NewsletterConfig): Promise<'confirmed' | 'used' | 'invalid' | 'unsubscribed'> {
  const client = await getClient();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      'SELECT email, completed_at, expires_at FROM newsletter_signups WHERE token_hash = $1 FOR UPDATE', [hashToken(token)],
    );
    const signup = rows[0];
    if (!signup || new Date(signup.expires_at).getTime() <= Date.now()) {
      await client.query('ROLLBACK');
      return 'invalid';
    }
    if (signup.completed_at) {
      await client.query('ROLLBACK');
      return 'used';
    }
    const contactId = await activateSubscriber(signup.email, settings);
    await client.query(
      'UPDATE newsletter_signups SET completed_at = now(), confirmed_at = now(), resend_contact_id = $2 WHERE token_hash = $1',
      [hashToken(token), contactId],
    );
    await client.query('COMMIT');
    return contactId ? 'confirmed' : 'unsubscribed';
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally { client.release(); }
}
