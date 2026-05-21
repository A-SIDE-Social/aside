import { Router } from 'express';
import crypto from 'crypto';
import { query, getClient } from '../db/pool';
import { authenticate, generateAccessToken, generateRefreshToken } from '../middleware/auth';
import { authLimit } from '../middleware/rateLimit';
import { asyncHandler, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { config } from '../config';
import { LIMITS, REVENUECAT_ENTITLEMENT, SYSTEM_USER_EMAIL } from '../constants';
import { sendOtpEmail } from '../email';
import { notifyNewUser } from '../notifications/discord';
import { generateUniqueSlug, extractSlug, SLUG_REGEX } from '../lib/slugs';
import {
  sendPush,
  getTokensForUsers,
  filterByPushThrottle,
  stampPushSent,
} from '../firebase';

const router = Router();

function hashToken(token: string): string {
  return crypto.createHash('sha256').update(token).digest('hex');
}

/**
 * Shared registration logic.
 * Looks up existing user by email or creates a new one.
 */
async function resolveUser(
  email: string,
  invite_code?: string,
  display_name?: string,
) {
  // Check if user exists
  const { rows: existingUsers } = await query(
    'SELECT * FROM users WHERE email = $1 AND deleted_at IS NULL',
    [email],
  );

  if (existingUsers.length > 0) {
    return existingUsers[0];
  }

  // New registration — display_name is required, invite_code is optional
  if (!display_name) {
    throw new AppError(400, 'display_name is required for registration');
  }

  // Validate the invite code BEFORE we touch the users table. Earlier
  // versions ran this check AFTER the INSERT, so a typo'd or expired
  // code would 400 the request but leave a partial account behind: on
  // retry, the existing-user branch returned the bare row without ever
  // running the invite-code allocation loop, stranding the user with
  // 0 codes. Migration 015 backfilled the affected rows.
  //
  // The `invite_code` field accepts THREE shapes:
  //   1. Legacy 12-char alphanumeric code (looked up in `invites`
  //      table). Creates a mutual follow with the inviter on signup.
  //   2. A 12-char lowercase alphanumeric slug from a personal invite
  //      link (looked up in `users.invite_slug`). Creates a one-way
  //      follow request to the slug owner; recipient approves
  //      manually via existing inbound-follows UI.
  //   3. A full URL on one of the configured invite-link hosts. We
  //      extract the slug via `extractSlug` and treat as (2).
  //
  // Disambiguation: we look up by slug FIRST (covers shapes 2 and 3
  // and lower-case 1's), then fall back to legacy code lookup. The
  // slug regex is a strict subset that excludes uppercase characters,
  // so a hex-only legacy code COULD match both — the slug lookup
  // settles ambiguity by hitting the DB.
  let validatedInvite: any = null;
  let validatedSlug: { user_id: string; display_name: string } | null = null;
  if (invite_code) {
    const trimmed = invite_code.toString().trim();
    const maybeSlug = extractSlug(trimmed, config.inviteLinkAllowedHosts);
    if (maybeSlug) {
      const { rows: slugUsers } = await query(
        `SELECT id, display_name
         FROM users
         WHERE LOWER(invite_slug) = LOWER($1)
           AND deleted_at IS NULL
           AND email != $2`,
        [maybeSlug, SYSTEM_USER_EMAIL],
      );
      if (slugUsers.length > 0) {
        validatedSlug = {
          user_id: slugUsers[0].id,
          display_name: slugUsers[0].display_name,
        };
      }
    }
    if (!validatedSlug) {
      // Accept BOTH 'pending' (never shared) and 'sent' (the inviter
      // tapped Share — the app PATCHes status to 'sent' to track that).
      // The friend-add path in src/routes/invites.ts:redeem has always
      // accepted both; this path was the odd one out, which silently
      // broke every shared code for new signups.
      const { rows: invites } = await query(
        `SELECT * FROM invites WHERE code = $1 AND status IN ('pending', 'sent') AND expires_at > NOW()`,
        [trimmed],
      );
      if (invites.length === 0) {
        throw new AppError(400, 'Invalid or already used invite code');
      }
      validatedInvite = invites[0];
    }
  }

  // Auto-generate an internal username from UUID (never shown to users)
  const autoUsername = 'u' + crypto.randomUUID().replace(/-/g, '').slice(0, 16);

  // Generate an opaque personal-invite slug for the new user. Done
  // outside the transaction (collision lookup uses the same pool) so
  // the transaction stays minimal. We re-check inside the transaction
  // via the unique index; a race with another signup grabbing the
  // same slug would surface as a unique_violation and roll back.
  const inviteSlug = await generateUniqueSlug(async (candidate) => {
    const { rows: existing } = await query(
      'SELECT 1 FROM users WHERE LOWER(invite_slug) = LOWER($1)',
      [candidate],
    );
    return existing.length > 0;
  });

  // Compute email hash for contact sync discovery
  const emailHash = crypto.createHash('sha256').update(email.toLowerCase()).digest('hex');

  // Wrap user creation + invite consumption + follow + 25-code allocation
  // in a single transaction. Any failure now rolls back the user row too,
  // so we can never end up with a half-registered account that the next
  // signup attempt would short-circuit past on `existingUsers.length > 0`.
  const client = await getClient();
  try {
    await client.query('BEGIN');

    const { rows: newUsers } = await client.query(
      `INSERT INTO users (email, email_hash, username, display_name, invite_slug)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING *`,
      [email, emailHash, autoUsername, display_name, inviteSlug],
    );
    const user = newUsers[0];

    if (validatedSlug) {
      // Personal-invite-link signup. Create a ONE-WAY follow from the
      // new user to the slug owner — owner must approve via inbound-
      // follows UI to make it mutual. Fires the same `inbound_follow`
      // notification shape as POST /v1/follows so the recipient's
      // existing surfaces handle it identically.
      await client.query(
        `INSERT INTO follows (follower_id, followee_id)
         VALUES ($1, $2)
         ON CONFLICT (follower_id, followee_id) DO NOTHING`,
        [user.id, validatedSlug.user_id],
      );
      await client.query(
        `INSERT INTO notifications (user_id, type, actor_id, reference_type)
         VALUES ($1, 'inbound_follow', $2, 'follow')`,
        [validatedSlug.user_id, user.id],
      );
    } else if (validatedInvite) {
      // Mark invite as used. Re-check status under the transaction so
      // two concurrent signups can't both consume the same code.
      // Mirrors the validation predicate above — accept either
      // 'pending' or 'sent'. Without the 'sent' branch, a signup
      // racing with the inviter's Share tap would lose the race and
      // be told the code is invalid even though it's still redeemable.
      const { rowCount } = await client.query(
        `UPDATE invites
            SET status = 'used', used_by_user_id = $1, used_at = NOW()
          WHERE id = $2 AND status IN ('pending', 'sent')`,
        [user.id, validatedInvite.id],
      );
      if ((rowCount ?? 0) === 0) {
        throw new AppError(400, 'Invalid or already used invite code');
      }

      // Create mutual follow with inviter
      await client.query(
        `INSERT INTO follows (follower_id, followee_id)
         VALUES ($1, $2), ($2, $1)`,
        [user.id, validatedInvite.created_by_user_id],
      );

      // TODO: Referral bonus disabled for launch. Revisit when we want
      // to reward referring *paying* users specifically, not just any
      // signup.
    }

    await allocateInvitesForUserOnClient(
      client,
      user.id,
      LIMITS.maxInvites,
    );

    await client.query('COMMIT');

    // Fire-and-forget Discord notification for the operator. Runs
    // POST-commit so we never notify about a transaction that
    // ultimately rolled back. Inviter lookup happens here rather
    // than folded into the existing invite-validation query so the
    // signup hot path stays minimal — Discord can be slow / down /
    // unconfigured and registration must succeed anyway.
    //
    // `void` because TypeScript's no-floating-promises is happier
    // when we explicitly mark "I'm not awaiting this." The IIFE
    // wraps the inviter lookup + notify as one async chunk that
    // catches any thrown error inside.
    void (async () => {
      try {
        let inviterName: string | null = null;
        if (validatedInvite) {
          const { rows: inviterRows } = await query(
            `SELECT display_name FROM users WHERE id = $1`,
            [validatedInvite.created_by_user_id],
          );
          inviterName = inviterRows[0]?.display_name ?? null;
        } else if (validatedSlug) {
          inviterName = validatedSlug.display_name;
        }
        await notifyNewUser({
          userId: user.id,
          displayName: user.display_name,
          email: user.email,
          inviteCode: invite_code ?? null,
          inviterName,
        });
      } catch (e) {
        // notifyNewUser already swallows network errors; this catch
        // is belt-and-suspenders in case the inviter lookup blows
        // up. Never propagate.
        console.warn('Discord notify post-commit failed:', e);
      }
    })();

    // Slug-based signup: push the slug owner so the inbound-follow
    // request shows up promptly. Fire-and-forget outside the
    // transaction — a push failure must not roll back a successful
    // signup. Respects the connections notification preference, same
    // as POST /v1/follows.
    if (validatedSlug) {
      void (async () => {
        try {
          const { rows: prefRows } = await query(
            'SELECT COALESCE((SELECT connections FROM notification_preferences WHERE user_id = $1), true) AS enabled',
            [validatedSlug.user_id],
          );
          if (!prefRows[0].enabled) return;
          const allowed = await filterByPushThrottle([validatedSlug.user_id]);
          if (allowed.length === 0) return;
          const tokens = await getTokensForUsers([validatedSlug.user_id]);
          if (tokens.length === 0) return;
          await sendPush(
            tokens,
            'Connection Request',
            `${user.display_name} wants to connect with you`,
            { type: 'inbound_follow', user_id: user.id },
          );
          await stampPushSent([validatedSlug.user_id]);
        } catch (e) {
          console.warn('Slug-signup inbound-follow push failed:', e);
        }
      })();
    }

    return user;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

/**
 * Default invite-code generator: 12-char hex prefix of a random UUID.
 * Exposed only so tests can swap it for a deterministic generator that
 * forces a collision on the first call.
 */
export const defaultInviteCodeGen = () =>
  crypto.randomUUID().replace(/-/g, '').slice(0, 12);

/**
 * Pool-based allocation. Each INSERT runs as its own implicit
 * transaction. Use `allocateInvitesForUserOnClient` instead when
 * you need to participate in a larger transaction (e.g., signup).
 *
 * Exported for testing (collision recovery + per-user-count regression).
 * Tests pass a `codeGen` that returns a known-colliding code first.
 */
export async function allocateInvitesForUser(
  userId: string,
  count: number,
  codeGen: () => string = defaultInviteCodeGen,
) {
  return allocateInvitesWith(query, userId, count, codeGen);
}

/**
 * Same as `allocateInvitesForUser` but runs all INSERTs against the
 * provided pg client — used by `resolveUser` so allocation participates
 * in the signup transaction. If any INSERT fails, the surrounding
 * BEGIN/COMMIT rolls everything back including the user row.
 */
export async function allocateInvitesForUserOnClient(
  client: { query: (text: string, params?: any[]) => Promise<any> },
  userId: string,
  count: number,
  codeGen: () => string = defaultInviteCodeGen,
) {
  return allocateInvitesWith(
    (text: string, params?: any[]) => client.query(text, params),
    userId,
    count,
    codeGen,
  );
}

async function allocateInvitesWith(
  exec: (text: string, params?: any[]) => Promise<{ rowCount: number | null }>,
  userId: string,
  count: number,
  codeGen: () => string,
) {
  const maxAttemptsPerCode = 5;
  for (let i = 0; i < count; i++) {
    let inserted = false;
    for (let attempt = 0; attempt < maxAttemptsPerCode; attempt++) {
      const code = codeGen();
      const { rowCount } = await exec(
        `INSERT INTO invites (created_by_user_id, code, status, expires_at)
         VALUES ($1, $2, 'pending', NOW() + INTERVAL '30 days')
         ON CONFLICT (code) DO NOTHING`,
        [userId, code],
      );
      if ((rowCount ?? 0) > 0) {
        inserted = true;
        break;
      }
    }
    if (!inserted) {
      throw new AppError(
        500,
        'Failed to allocate invite codes after retries',
      );
    }
  }
}

/**
 * Issue JWTs and store refresh token.
 */
async function issueTokens(userId: string) {
  const accessToken = generateAccessToken(userId);
  const refreshToken = generateRefreshToken(userId);

  const hashedToken = hashToken(refreshToken);
  const refreshExpiresAt = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000);
  await query(
    'INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)',
    [userId, hashedToken, refreshExpiresAt],
  );

  return { accessToken, refreshToken };
}

// POST /request-otp — send a 6-digit code to the user's email
router.post(
  '/request-otp',
  authLimit,
  asyncHandler(async (req: any, res: any) => {
    const { email } = req.body;
    if (!email) throw new AppError(400, 'Email is required');

    const normalizedEmail = email.trim().toLowerCase();

    // Rate limit: max 1 OTP per 30 seconds per email
    const { rows: recent } = await query(
      `SELECT 1 FROM email_otps WHERE email = $1 AND created_at > NOW() - INTERVAL '30 seconds'`,
      [normalizedEmail],
    );
    if (recent.length > 0) {
      throw new AppError(429, 'Please wait before requesting another code');
    }

    // Generate OTP.
    //
    // DEV_OTP is an email-scoped backdoor used to let App Store
    // reviewers (and devs) sign in without a real email round-trip.
    // Scoping rules:
    //
    //   - In development/test NODE_ENV: applies to every email.
    //     Matches historical behavior for local work.
    //   - In production NODE_ENV: applies ONLY to emails in
    //     DEV_OTP_ALLOWED_EMAILS. If the allowlist is empty in prod,
    //     DEV_OTP is ignored — we NEVER turn it on globally for
    //     real TestFlight testers, who must get a genuine random OTP
    //     via Postmark.
    //
    // This guardrail exists because leaving DEV_OTP globally on in
    // prod is equivalent to letting anyone log in as any email they
    // know — a full authentication bypass masquerading as a testing
    // convenience.
    const isDevEnv =
      config.nodeEnv === 'development' || config.nodeEnv === 'test';
    // In dev/test: DEV_OTP applies to every email, but only when it
    // is explicitly configured. Without DEV_OTP, dev/test requests
    // still generate a random code and send/log through sendOtpEmail.
    //
    // In production: DEV_OTP applies ONLY to emails explicitly listed
    // in DEV_OTP_ALLOWED_EMAILS (typically App Store reviewers). Any
    // other email gets a genuine random OTP via Postmark. If DEV_OTP
    // is unset in prod, the allowlist is ignored and no backdoor
    // exists.
    const emailAllowedForDevOtp = !!config.devOtp &&
      (isDevEnv || config.devOtpAllowedEmails.includes(normalizedEmail));
    const code = emailAllowedForDevOtp
      ? config.devOtp
      : crypto.randomInt(100000, 999999).toString();

    // Hash and store
    const codeHash = crypto.createHash('sha256').update(code).digest('hex');

    // Delete any previous OTPs for this email
    await query('DELETE FROM email_otps WHERE email = $1', [normalizedEmail]);

    // Insert new OTP with 10-minute expiry
    await query(
      `INSERT INTO email_otps (email, code_hash, expires_at)
       VALUES ($1, $2, NOW() + INTERVAL '10 minutes')`,
      [normalizedEmail, codeHash],
    );

    // Send the OTP email via Postmark.
    //
    // Skip delivery entirely for allowlisted dev-OTP emails (reviewers,
    // internal testers). Those addresses already know the code from
    // review notes, don't need the email, and attempting to actually
    // deliver to them can fail — @apple.com in particular is subject
    // to aggressive spam filtering and can cause Postmark to return
    // errors that bubble up as a 500 on the mobile side, which has
    // historically gotten App Review submissions rejected for showing
    // an error on the email-entry screen.
    //
    // For everyone else we still call Postmark and let errors
    // propagate — a real user who doesn't get their OTP email needs
    // to know something went wrong so they can retry.
    if (!emailAllowedForDevOtp) {
      await sendOtpEmail(normalizedEmail, code);
    }

    res.json({ message: 'OTP sent' });
  }),
);

// POST /verify-otp — verify the code and authenticate/register
router.post(
  '/verify-otp',
  authLimit,
  asyncHandler(async (req: any, res: any) => {
    const { email, code, invite_code, display_name } = req.body;
    if (!email || !code) throw new AppError(400, 'Email and code are required');

    const normalizedEmail = email.trim().toLowerCase();

    // Look up the OTP
    const { rows: otps } = await query(
      `SELECT * FROM email_otps WHERE email = $1 AND expires_at > NOW() ORDER BY created_at DESC LIMIT 1`,
      [normalizedEmail],
    );
    if (otps.length === 0) throw new AppError(401, 'Invalid or expired code');

    const otp = otps[0];

    // Check attempt limit
    if (otp.attempts >= 5) {
      await query('DELETE FROM email_otps WHERE id = $1', [otp.id]);
      throw new AppError(401, 'Too many attempts. Please request a new code.');
    }

    // Increment attempts
    await query('UPDATE email_otps SET attempts = attempts + 1 WHERE id = $1', [otp.id]);

    // Compare hashes
    const submittedHash = crypto.createHash('sha256').update(code).digest('hex');
    if (submittedHash !== otp.code_hash) {
      throw new AppError(401, 'Invalid code');
    }

    // OTP is valid — resolve user (may throw 400 if display_name needed)
    // We do NOT delete the OTP yet — if resolveUser throws (missing display_name),
    // the client can retry with registration data using the same code.
    const user = await resolveUser(normalizedEmail, invite_code, display_name);

    // Success — delete the OTP
    await query('DELETE FROM email_otps WHERE id = $1', [otp.id]);

    const { accessToken, refreshToken } = await issueTokens(user.id);

    // Resolve avatar_url to a full CDN/dev URL before sending. The
    // resolveUser helper returns the raw DB row where avatar_url is an
    // S3 key (UUID, no scheme), so the mobile client would try to load
    // a bare key as a URL and show the initials-fallback avatar. Every
    // other user-returning endpoint (GET /users/me, PATCH /users/me,
    // GET /users/:id, by-user, feed) already runs resolveMediaUrl on
    // avatar_url — this is the only login path that was missing it.
    // Symptom: fresh install on a second device would show initials
    // until a force-quit/relaunch, because initialize() then hits
    // /users/me which resolves correctly.
    if (user.avatar_url) {
      user.avatar_url = resolveMediaUrl(user.avatar_url, req);
    }

    res.json({
      access_token: accessToken,
      refresh_token: refreshToken,
      user,
    });
  }),
);

// POST /refresh
router.post(
  '/refresh',
  asyncHandler(async (req: any, res: any) => {
    const { refresh_token } = req.body;
    if (!refresh_token) throw new AppError(400, 'Refresh token is required');

    const hashedToken = hashToken(refresh_token);
    const { rows } = await query(
      'SELECT * FROM refresh_tokens WHERE token_hash = $1',
      [hashedToken],
    );
    if (rows.length === 0) throw new AppError(401, 'Invalid refresh token');

    // Verify the JWT is still valid
    const jwt = await import('jsonwebtoken');
    try {
      const payload = jwt.default.verify(refresh_token, config.jwtRefreshSecret) as { userId: string };
      const accessToken = generateAccessToken(payload.userId);
      res.json({ access_token: accessToken });
    } catch {
      // Remove invalid token
      await query('DELETE FROM refresh_tokens WHERE token_hash = $1', [hashedToken]);
      throw new AppError(401, 'Refresh token expired');
    }
  }),
);

// DELETE /session
router.delete(
  '/session',
  authenticate,
  asyncHandler(async (req: any, res: any) => {
    const { refresh_token } = req.body;
    if (!refresh_token) throw new AppError(400, 'Refresh token is required');

    const hashedToken = hashToken(refresh_token);
    await query('DELETE FROM refresh_tokens WHERE token_hash = $1 AND user_id = $2', [
      hashedToken,
      req.user!.userId,
    ]);

    res.json({ message: 'Session ended' });
  }),
);

export default router;
