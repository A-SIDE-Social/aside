import crypto from 'crypto';
import { config } from '../config';
import { getClient, query } from '../db/pool';
import { OtpDeliveryError, sendOtpEmail } from '../email';
import { AppError } from '../middleware/errorHandler';

/** Both mobile and admin login share the same per-address code and cooldown. */
export async function requestEmailOtp(email: string): Promise<void> {
  const isDev = config.nodeEnv === 'development' || config.nodeEnv === 'test';
  // A fixed reviewer code must never apply to arbitrary production addresses.
  const skipDelivery = !!config.devOtp && (isDev || config.devOtpAllowedEmails.includes(email));
  const code = skipDelivery ? config.devOtp : crypto.randomInt(100000, 1000000).toString();
  const codeHash = crypto.createHash('sha256').update(code).digest('hex');

  const client = await getClient();
  let otpId: string;
  try {
    await client.query('BEGIN');
    // Serialize the check and replacement even when there is no existing row.
    // The transaction ends before Postmark is called; network delays hold no lock.
    await client.query("SELECT pg_advisory_xact_lock(hashtextextended('email-otp:' || $1::text, 0))", [email]);
    const { rows: recent } = await client.query(
      `SELECT 1 FROM email_otps WHERE email = $1
       AND created_at > clock_timestamp() - INTERVAL '30 seconds'`, [email],
    );
    if (recent.length) throw new AppError(429, 'Please wait before requesting another code', 'rate_limited');
    await client.query('DELETE FROM email_otps WHERE email = $1', [email]);
    const { rows } = await client.query<{ id: string }>(
      `INSERT INTO email_otps (email, code_hash, expires_at, created_at)
       VALUES ($1, $2, clock_timestamp() + INTERVAL '10 minutes', clock_timestamp()) RETURNING id`,
      [email, codeHash],
    );
    otpId = rows[0].id;
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {
      console.warn('[OTP] Storage rollback failed');
    });
    throw error;
  } finally {
    client.release();
  }

  if (skipDelivery) return;
  try {
    await sendOtpEmail(email, code);
  } catch (error) {
    if (error instanceof OtpDeliveryError && error.definitelyRejected) {
      // Retain created_at to enforce the cooldown, but make this code unusable.
      // A delayed failure must never invalidate a subsequent request's code.
      await query('UPDATE email_otps SET expires_at = clock_timestamp() WHERE id = $1', [otpId])
        .catch(() => { console.warn('[OTP] Failed to expire rejected code'); });
    }
    // A timeout/connection loss may happen after acceptance. Preserve that code
    // until normal expiry and never automatically resend an ambiguous request.
    throw error;
  }
}
