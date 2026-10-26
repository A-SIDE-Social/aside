import crypto from 'crypto';
import jwt from 'jsonwebtoken';
import { config } from '../config';
import { getClient } from '../db/pool';
import { generateAccessToken } from '../middleware/auth';
import { AppError } from '../middleware/errorHandler';
import type { FailureReason } from '../lib/failureReason';

export const sessionIdleDays = 365;
const hash = (value: string) => crypto.createHash('sha256').update(value).digest('hex');
const rejected = (reason: FailureReason, status = 401) =>
  new AppError(status, 'Session could not be renewed', reason);

export function newSessionCredential(sessionId: string): string {
  return `rt2.${sessionId}.${crypto.randomBytes(32).toString('base64url')}`;
}

// Deterministic only on the server: an interrupted response can return the same
// successor without storing a plaintext/encrypted bearer credential in the DB.
function successor(sessionId: string, credential: string): string {
  const secret = crypto.createHmac('sha256', config.jwtRefreshSecret)
    .update('session-rotation-v1\0').update(credential).digest('base64url');
  return `rt2.${sessionId}.${secret}`;
}

export async function refreshSession(credential: unknown, nonce: unknown) {
  if (typeof credential !== 'string' || !credential || credential.length > 4096) {
    throw new AppError(400, 'Refresh token is required', 'refresh_invalid');
  }
  const rotating = nonce !== undefined;
  if (rotating && (typeof nonce !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(nonce))) {
    throw new AppError(400, 'Invalid refresh request', 'refresh_invalid');
  }
  const fingerprint = hash(credential);
  const client = await getClient();
  let committed = false;
  try {
    await client.query('BEGIN');
    // Resolve the stable row ID before locking. Locking by a changing hash can
    // lose a concurrent rotation under READ COMMITTED's row recheck.
    const located = (await client.query(
      `SELECT id FROM refresh_tokens WHERE token_hash = $1 OR id = (
         SELECT session_id FROM refresh_token_rotations WHERE token_hash = $1
       )`, [fingerprint],
    )).rows[0];
    if (!located) throw rejected('refresh_unknown');
    const { rows } = await client.query(
      `SELECT rt.*, u.deleted_at, rt.expires_at > clock_timestamp() AS live
       FROM refresh_tokens rt JOIN users u ON u.id = rt.user_id
       WHERE rt.id = $1 FOR UPDATE OF rt`, [located.id],
    );
    const session = rows[0];
    if (!session) throw rejected('refresh_unknown');
    if (session.deleted_at) throw rejected('refresh_inactive_account');
    if (session.revoked_at) throw rejected('refresh_revoked');
    if (!session.live) throw rejected(session.rotation_enabled
      ? 'refresh_idle_expired' : 'refresh_legacy_expired');

    // Legacy credentials migrate only while their original session is valid.
    // No expired/revoked session is revived, and signatures are never bypassed.
    if (!credential.startsWith('rt2.')) {
      try {
        const payload = jwt.verify(credential, config.jwtRefreshSecret,
          { algorithms: ['HS256'],
            // Only a previously rotated credential may outlive its legacy
            // JWT date, and only with the recorded retry secret below. The
            // live, revocable server session still enforces inactivity expiry.
            ignoreExpiration: session.token_hash !== fingerprint && rotating });
        if (typeof payload === 'string' || payload.userId !== session.user_id) {
          throw new Error('Invalid session');
        }
      } catch (error) {
        throw rejected(error instanceof jwt.TokenExpiredError
          ? 'refresh_legacy_expired' : 'refresh_invalid');
      }
    }

    if (session.token_hash !== fingerprint) {
      const previous = (await client.query(
        'SELECT request_hash, next_hash, used_at FROM refresh_token_rotations WHERE token_hash = $1',
        [fingerprint],
      )).rows[0];
      if (!previous) throw rejected('refresh_unknown');
      if (!rotating) throw rejected('refresh_invalid');
      if (previous.request_hash !== hash(nonce as string)) {
        await client.query('UPDATE refresh_tokens SET revoked_at = clock_timestamp() WHERE id = $1', [session.id]);
        await client.query('COMMIT');
        committed = true;
        throw rejected('refresh_reused');
      }
      if (previous.next_hash !== session.token_hash) {
        // Briefly tolerate overlapping acknowledged attempts, without minting
        // credentials. Beyond this window, replay ends the session even if
        // both the old token and its retry secret were copied.
        if (Date.now() - new Date(previous.used_at).getTime() <= 60000) {
          throw rejected('refresh_superseded', 409);
        }
        await client.query('UPDATE refresh_tokens SET revoked_at = clock_timestamp() WHERE id = $1', [session.id]);
        await client.query('COMMIT');
        committed = true;
        throw rejected('refresh_reused');
      }
      const next = successor(session.id, credential);
      await client.query('COMMIT');
      committed = true;
      return { access_token: generateAccessToken(session.user_id), refresh_token: next };
    }

    if (!rotating) {
      // Older mobile builds retain their existing behavior until upgraded.
      // Never permit a rotated session to fall back to reusable credentials.
      if (session.rotation_enabled) throw rejected('refresh_invalid');
      await client.query('COMMIT');
      committed = true;
      return { access_token: generateAccessToken(session.user_id) };
    }

    const next = successor(session.id, credential);
    await client.query(
      `INSERT INTO refresh_token_rotations (token_hash, session_id, request_hash, next_hash)
       VALUES ($1, $2, $3, $4)`, [fingerprint, session.id, hash(nonce as string), hash(next)],
    );
    await client.query(
      `UPDATE refresh_tokens SET token_hash = $2, rotation_enabled = true,
         expires_at = clock_timestamp() + $3::int * INTERVAL '1 day' WHERE id = $1`,
      [session.id, hash(next), sessionIdleDays],
    );
    // Keep the latest retry recoverable while the idle session is live. Older
    // replay fingerprints have a bounded 30-day retention; unknown old tokens
    // still cannot authenticate after pruning.
    await client.query(
      `DELETE FROM refresh_token_rotations WHERE session_id = $1
       AND next_hash <> $2 AND used_at < clock_timestamp() - INTERVAL '30 days'`,
      [session.id, hash(next)],
    );
    await client.query('COMMIT');
    committed = true;
    return { access_token: generateAccessToken(session.user_id), refresh_token: next };
  } catch (error) {
    if (!committed) await client.query('ROLLBACK');
    throw error;
  } finally { client.release(); }
}
