// Stateless one-click unsubscribe tokens.
//
// Each token is `<userId>.<HMAC-SHA256(userId, JWT_SECRET)>` —
// signed with the same JWT secret so an unset env doesn't create
// a parallel secret to rotate. Verification is a single HMAC
// recompute + constant-time compare, no DB lookup.
//
// We deliberately do NOT include a timestamp / expiry: an
// unsubscribe link in a months-old email should still work.
// Replay isn't a concern — re-clicking just re-flips an already-
// false flag.

import crypto from 'crypto';
import { config } from '../config';

function sign(userId: string): string {
  return crypto
    .createHmac('sha256', config.jwtSecret)
    .update(userId)
    .digest('hex');
}

export function makeUnsubscribeToken(userId: string): string {
  return `${userId}.${sign(userId)}`;
}

/// Returns the user_id if the token is valid, or null if the
/// signature doesn't match (tampered / wrong secret).
export function verifyUnsubscribeToken(token: string): string | null {
  if (typeof token !== 'string' || !token.includes('.')) return null;
  const dotIdx = token.indexOf('.');
  const userId = token.slice(0, dotIdx);
  const submitted = token.slice(dotIdx + 1);
  if (!userId || !submitted) return null;
  const expected = sign(userId);
  if (submitted.length !== expected.length) return null;
  try {
    return crypto.timingSafeEqual(
      Buffer.from(submitted, 'hex'),
      Buffer.from(expected, 'hex'),
    )
      ? userId
      : null;
  } catch {
    // Buffer.from with non-hex chars throws — treat as invalid.
    return null;
  }
}
