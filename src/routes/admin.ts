// Admin web UI — operator-facing dashboard for quick fixes that
// would otherwise require SSH'ing into the prod container and
// running raw SQL. Mounted at /admin (outside the /v1 API
// namespace).
//
// Auth: same OTP flow as the mobile app, but the OTP-request step
// gates against the admin allowlist (only emails belonging to a
// user_id in ADMIN_USER_IDS can request a code), and the JWT issued
// at verify time is checked against the same allowlist on every
// subsequent request via the adminOnly middleware. Session lives
// in an HttpOnly + Secure + SameSite=Strict signed cookie.
//
// Visual style matches the marketing site's editorial register —
// warm cream background, Geist body, serif H1 — but stripped down
// for table density. Single-operator tool; no responsive layout.

import { Router, Request, Response } from 'express';
import crypto from 'crypto';
import jwt from 'jsonwebtoken';
import { query } from '../db/pool';
import { config } from '../config';
import { authLimit, writeLimit } from '../middleware/rateLimit';
import { asyncHandler } from '../helpers';
import { generateAccessToken } from '../middleware/auth';
import { sendOtpEmail } from '../email';
import {
  adminOnly,
  ADMIN_COOKIE,
  adminCookieOptions,
} from '../middleware/adminOnly';

export const adminRouter = Router();

const CSRF_COOKIE = 'admin_csrf';
const csrfCookieOptions = {
  ...adminCookieOptions,
  // CSRF cookie can be the same path scope as the session.
};

// ── Helpers ─────────────────────────────────────────────────────────

/// Minimal HTML escaping for embedding untrusted strings in the
/// templates below. We never render user-controlled HTML on the
/// admin pages, but the table cells contain emails / display names /
/// IDs which could contain `<` etc.
function esc(s: unknown): string {
  if (s == null) return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/// Generate a random 32-byte hex CSRF token.
function newCsrf(): string {
  return crypto.randomBytes(32).toString('hex');
}

/// Read the admin's CSRF cookie or set a new one if absent. Used at
/// every form-render step so the hidden input always carries a
/// valid token.
function ensureCsrf(req: Request, res: Response): string {
  const existing = req.signedCookies?.[CSRF_COOKIE];
  if (typeof existing === 'string' && existing.length === 64) {
    return existing;
  }
  const fresh = newCsrf();
  res.cookie(CSRF_COOKIE, fresh, csrfCookieOptions);
  return fresh;
}

/// Verify a submitted CSRF token against the cookie. Constant-time
/// to dodge timing-leak nitpicks even though the threat model
/// doesn't really need it for a single-operator tool.
function verifyCsrf(req: Request): boolean {
  const cookie = req.signedCookies?.[CSRF_COOKIE];
  const submitted = req.body?.csrf;
  if (typeof cookie !== 'string' || typeof submitted !== 'string') return false;
  if (cookie.length !== submitted.length) return false;
  return crypto.timingSafeEqual(
    Buffer.from(cookie),
    Buffer.from(submitted),
  );
}

/// Insert an admin_audit row. Called from every mutation handler.
async function writeAudit(
  req: Request,
  action: string,
  targetUserId: string | null,
  details: Record<string, unknown>,
): Promise<void> {
  const adminId = req.user?.userId;
  if (!adminId) return; // shouldn't happen post-adminOnly
  await query(
    `INSERT INTO admin_audit
       (admin_user_id, action, target_user_id, details, ip_address, user_agent)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [
      adminId,
      action,
      targetUserId,
      JSON.stringify(details),
      req.ip ?? null,
      typeof req.headers['user-agent'] === 'string'
        ? req.headers['user-agent']
        : null,
    ],
  );
}

/// SHA-256 hex of the lowercased email — same shape used in the
/// users.email_hash column for contact-discovery matching.
function emailHash(email: string): string {
  return crypto.createHash('sha256')
    .update(email.toLowerCase())
    .digest('hex');
}

// ── Auth (login / logout) ───────────────────────────────────────────

adminRouter.get('/login', (req, res) => {
  ensureCsrf(req, res);
  res.type('html').send(layout({
    title: 'Sign in',
    body: `
      <h1>A/SIDE admin</h1>
      <p class="muted">Operator access only. Sign in with the email
        bound to your admin account; you'll receive a 6-digit code.</p>
      <form method="post" action="/admin/login/request-otp">
        <label>Email
          <input type="email" name="email" required autocomplete="email" autofocus>
        </label>
        <button type="submit">Send code</button>
      </form>
    `,
  }));
});

adminRouter.post(
  '/login/request-otp',
  authLimit,
  express_urlencoded(),
  asyncHandler(async (req: Request, res: Response) => {
    const email = String(req.body?.email ?? '').trim().toLowerCase();
    if (!email) {
      return res.status(400).type('html').send(layout({
        title: 'Sign in',
        body: '<p>Email is required. <a href="/admin/login">Try again</a>.</p>',
      }));
    }

    // Look up the user. We do this before sending an OTP so we can
    // gate against the admin allowlist — admin email check.
    const { rows } = await query(
      `SELECT id FROM users WHERE LOWER(email) = $1 AND deleted_at IS NULL`,
      [email],
    );
    const isAdmin =
      rows.length > 0 && config.adminUserIds.includes(rows[0].id);

    // Whether or not the email belongs to an admin, return the
    // same generic UI — no enumeration. If they ARE an admin, we
    // actually generate + send the OTP through the same path the
    // mobile auth uses.
    if (isAdmin) {
      // Reuse the dev-OTP gate that the mobile flow uses, so a
      // reviewer / dev can sign into the dashboard with the same
      // 123456 they use in the mobile app.
      const isDevEnv =
        config.nodeEnv === 'development' || config.nodeEnv === 'test';
      const emailAllowedForDevOtp =
        isDevEnv ||
        (!!config.devOtp && config.devOtpAllowedEmails.includes(email));
      const code = emailAllowedForDevOtp
        ? config.devOtp || '123456'
        : crypto.randomInt(100000, 999999).toString();
      const codeHash = crypto.createHash('sha256').update(code).digest('hex');

      // Replace any previous OTP for this address (same shape as
      // the mobile flow).
      await query('DELETE FROM email_otps WHERE email = $1', [email]);
      await query(
        `INSERT INTO email_otps (email, code_hash, expires_at)
         VALUES ($1, $2, NOW() + INTERVAL '10 minutes')`,
        [email, codeHash],
      );
      if (!emailAllowedForDevOtp) {
        await sendOtpEmail(email, code);
      }
    }

    // Either way, render the verify form. The pending email is
    // carried in the URL so refreshing the verify page doesn't
    // strand them.
    ensureCsrf(req, res);
    res.type('html').send(layout({
      title: 'Enter code',
      body: `
        <h1>Check your email</h1>
        <p class="muted">If <code>${esc(email)}</code> is an admin
          address, a 6-digit code was sent. Enter it below.</p>
        <form method="post" action="/admin/login/verify-otp">
          <input type="hidden" name="email" value="${esc(email)}">
          <input type="hidden" name="csrf" value="${ensureCsrf(req, res)}">
          <label>Code
            <input type="text" name="code" inputmode="numeric"
              pattern="[0-9]{6}" maxlength="6" required autofocus>
          </label>
          <button type="submit">Sign in</button>
        </form>
        <p class="muted small">
          <a href="/admin/login">Use a different email</a>
        </p>
      `,
    }));
  }),
);

adminRouter.post(
  '/login/verify-otp',
  authLimit,
  express_urlencoded(),
  asyncHandler(async (req: Request, res: Response) => {
    if (!verifyCsrf(req)) {
      return res.status(403).type('html').send(layout({
        title: 'Sign in',
        body: '<p>Invalid form submission. <a href="/admin/login">Start over</a>.</p>',
      }));
    }

    const email = String(req.body?.email ?? '').trim().toLowerCase();
    const code = String(req.body?.code ?? '').trim();
    if (!email || !code) {
      return res.redirect('/admin/login');
    }

    // Look up + verify OTP exactly like /v1/auth/verify-otp does,
    // but without resolveUser (admin must already exist).
    const { rows: otps } = await query(
      `SELECT * FROM email_otps WHERE email = $1 AND expires_at > NOW()
         ORDER BY created_at DESC LIMIT 1`,
      [email],
    );
    if (otps.length === 0) {
      return res.status(401).type('html').send(layout({
        title: 'Sign in',
        body: '<p>Code expired or not found. <a href="/admin/login">Try again</a>.</p>',
      }));
    }
    const otp = otps[0];
    if (otp.attempts >= 5) {
      await query('DELETE FROM email_otps WHERE id = $1', [otp.id]);
      return res.status(401).type('html').send(layout({
        title: 'Sign in',
        body: '<p>Too many attempts. <a href="/admin/login">Request a new code</a>.</p>',
      }));
    }
    await query(
      'UPDATE email_otps SET attempts = attempts + 1 WHERE id = $1',
      [otp.id],
    );
    const submittedHash = crypto.createHash('sha256').update(code).digest('hex');
    if (submittedHash !== otp.code_hash) {
      return res.status(401).type('html').send(layout({
        title: 'Sign in',
        body: `<p>Invalid code. <a href="/admin/login">Try again</a>.</p>`,
      }));
    }

    // Resolve the user + check admin allowlist.
    const { rows: users } = await query(
      `SELECT id FROM users WHERE LOWER(email) = $1 AND deleted_at IS NULL`,
      [email],
    );
    if (users.length === 0 || !config.adminUserIds.includes(users[0].id)) {
      // Still consume the OTP so it can't be reused.
      await query('DELETE FROM email_otps WHERE id = $1', [otp.id]);
      return res.status(403).type('html').send(layout({
        title: 'Sign in',
        body: '<p>Account not authorised for admin access.</p>',
      }));
    }

    // Success — consume OTP, issue JWT, set cookie, redirect.
    await query('DELETE FROM email_otps WHERE id = $1', [otp.id]);
    const token = generateAccessToken(users[0].id);
    res.cookie(ADMIN_COOKIE, token, adminCookieOptions);
    // Rotate the CSRF token on login so a pre-login token can't be
    // smuggled into a post-login session.
    res.cookie(CSRF_COOKIE, newCsrf(), csrfCookieOptions);
    res.redirect('/admin/users');
  }),
);

adminRouter.post(
  '/logout',
  express_urlencoded(),
  (req: Request, res: Response) => {
    res.clearCookie(ADMIN_COOKIE, { path: '/admin' });
    res.clearCookie(CSRF_COOKIE, { path: '/admin' });
    res.redirect('/admin/login');
  },
);

// ── Protected routes ────────────────────────────────────────────────

adminRouter.get('/', adminOnly, (_req, res) => {
  res.redirect('/admin/users');
});

adminRouter.get(
  '/users',
  adminOnly,
  asyncHandler(async (req: Request, res: Response) => {
    const search = String(req.query?.search ?? '').trim();
    const limit = 50;
    const offset = Math.max(0, parseInt(String(req.query?.offset ?? '0'), 10));

    const params: any[] = [];
    let where = '';
    if (search) {
      params.push(`%${search}%`);
      where = `WHERE (email ILIKE $1 OR display_name ILIKE $1)`;
    }
    params.push(limit, offset);

    const { rows } = await query(
      `SELECT id, email, display_name, subscription_status,
              subscription_plan, created_at, deleted_at
         FROM users
         ${where}
         ORDER BY created_at DESC
         LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    );

    const csrf = ensureCsrf(req, res);
    res.type('html').send(layout({
      title: 'Users',
      nav: 'users',
      body: `
        <h1>Users</h1>
        <form method="get" action="/admin/users" class="search">
          <input type="text" name="search" value="${esc(search)}"
            placeholder="Search by email or display name" autofocus>
          <button type="submit">Search</button>
          ${search ? `<a class="muted" href="/admin/users">Clear</a>` : ''}
        </form>
        <table>
          <thead>
            <tr>
              <th>Email</th>
              <th>Name</th>
              <th>Plan</th>
              <th>Created</th>
              <th>State</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            ${rows.map((u) => `
              <tr ${u.deleted_at ? 'class="deleted"' : ''}>
                <td><a href="/admin/users/${esc(u.id)}">${esc(u.email ?? '—')}</a></td>
                <td>${esc(u.display_name)}</td>
                <td>${esc(planLabel(u.subscription_plan, u.subscription_status))}</td>
                <td class="muted small">${esc(formatDate(u.created_at))}</td>
                <td>${u.deleted_at ? '<span class="badge badge-warn">Deleted</span>' : '<span class="badge">Active</span>'}</td>
                <td><a class="muted" href="/admin/users/${esc(u.id)}">Open →</a></td>
              </tr>
            `).join('')}
            ${rows.length === 0 ? '<tr><td colspan="6" class="muted center">No users found.</td></tr>' : ''}
          </tbody>
        </table>
        <p class="muted small">
          Showing ${rows.length} (offset ${offset}).
          ${rows.length === limit ? `<a href="/admin/users?search=${encodeURIComponent(search)}&offset=${offset + limit}">Next ${limit} →</a>` : ''}
          ${offset > 0 ? ` <a href="/admin/users?search=${encodeURIComponent(search)}&offset=${Math.max(0, offset - limit)}">← Previous</a>` : ''}
        </p>
        <input type="hidden" id="csrf" value="${csrf}">
      `,
    }));
  }),
);

adminRouter.get(
  '/users/:id',
  adminOnly,
  asyncHandler(async (req: Request, res: Response) => {
    const id = String(req.params.id);

    const { rows: users } = await query(
      `SELECT id, email, email_hash, display_name, username, avatar_url, bio,
              phone_e164, subscription_status, subscription_plan,
              marketing_opt_in, marketing_opted_out_at,
              created_at, updated_at, deleted_at
         FROM users WHERE id = $1`,
      [id],
    );
    if (users.length === 0) {
      return res.status(404).type('html').send(layout({
        title: 'User not found',
        body: '<p>No user with that id. <a href="/admin/users">Back to users</a>.</p>',
      }));
    }
    const u = users[0];

    const { rows: sessions } = await query(
      `SELECT id, expires_at, revoked_at, created_at
         FROM refresh_tokens WHERE user_id = $1
         ORDER BY created_at DESC LIMIT 10`,
      [id],
    );
    const activeSessions = sessions.filter(
      (s) => !s.revoked_at && new Date(s.expires_at) > new Date(),
    ).length;

    const { rows: postCountRows } = await query(
      `SELECT COUNT(*)::int AS n FROM posts WHERE user_id = $1 AND deleted_at IS NULL`,
      [id],
    );
    const postCount = postCountRows[0]?.n ?? 0;

    const csrf = ensureCsrf(req, res);
    res.type('html').send(layout({
      title: u.display_name,
      nav: 'users',
      body: `
        <p class="breadcrumb"><a href="/admin/users">← Users</a></p>
        <h1>${esc(u.display_name)}</h1>
        <p class="muted">${esc(u.email ?? 'no email')} · <code class="small">${esc(u.id)}</code></p>

        <section class="grid">
          <div>
            <div class="label">Plan</div>
            <div>${esc(planLabel(u.subscription_plan, u.subscription_status))}</div>
          </div>
          <div>
            <div class="label">Posts</div>
            <div>${postCount}</div>
          </div>
          <div>
            <div class="label">Active sessions</div>
            <div>${activeSessions} of ${sessions.length} recent</div>
          </div>
          <div>
            <div class="label">Created</div>
            <div class="small">${esc(formatDate(u.created_at))}</div>
          </div>
          <div>
            <div class="label">Updated</div>
            <div class="small">${esc(formatDate(u.updated_at))}</div>
          </div>
          <div>
            <div class="label">State</div>
            <div>${u.deleted_at ? '<span class="badge badge-warn">Deleted ' + esc(formatDate(u.deleted_at)) + '</span>' : '<span class="badge">Active</span>'}</div>
          </div>
        </section>

        <h2>Change email</h2>
        <p class="muted small">Updates <code>email</code> and recomputes
          <code>email_hash</code>; also clears any pending OTPs for both
          the old and new addresses.</p>
        <form method="post" action="/admin/users/${esc(u.id)}/email">
          <input type="hidden" name="csrf" value="${csrf}">
          <label>New email
            <input type="email" name="new_email" required>
          </label>
          <button type="submit">Change email</button>
        </form>

        <h2>Sessions</h2>
        <p class="muted small">Revokes all refresh tokens for this user.
          They'll be forced to sign in again on next app launch.</p>
        <form method="post" action="/admin/users/${esc(u.id)}/sessions/revoke"
              onsubmit="return confirm('Revoke all sessions for ${esc(u.display_name)}?');">
          <input type="hidden" name="csrf" value="${csrf}">
          <button type="submit" class="danger">Revoke ${activeSessions} active session(s)</button>
        </form>

        <h2>Marketing email</h2>
        <p class="muted small">
          ${u.marketing_opt_in
            ? `Opted in. Will receive broadcasts.`
            : `Opted out${u.marketing_opted_out_at ? ' on ' + esc(formatDate(u.marketing_opted_out_at)) : ''}. Will be skipped by every send.`}
        </p>
        <form method="post" action="/admin/users/${esc(u.id)}/marketing-opt-in/toggle">
          <input type="hidden" name="csrf" value="${csrf}">
          <button type="submit">
            ${u.marketing_opt_in ? 'Opt out of marketing' : 'Opt back in to marketing'}
          </button>
        </form>

        <h2>Account state</h2>
        ${u.deleted_at ? `
          <form method="post" action="/admin/users/${esc(u.id)}/restore"
                onsubmit="return confirm('Restore ${esc(u.display_name)}?');">
            <input type="hidden" name="csrf" value="${csrf}">
            <button type="submit">Restore account</button>
          </form>
        ` : `
          <form method="post" action="/admin/users/${esc(u.id)}/delete"
                onsubmit="return confirm('Soft-delete ${esc(u.display_name)}?');">
            <input type="hidden" name="csrf" value="${csrf}">
            <button type="submit" class="danger">Soft delete account</button>
          </form>
        `}
      `,
    }));
  }),
);

adminRouter.post(
  '/users/:id/email',
  adminOnly,
  writeLimit,
  express_urlencoded(),
  asyncHandler(async (req: Request, res: Response) => {
    if (!verifyCsrf(req)) {
      return res.status(403).type('html').send(layout({
        title: 'Forbidden',
        body: '<p>CSRF check failed. <a href="/admin/users">Back to users</a>.</p>',
      }));
    }

    const id = String(req.params.id);
    const newEmail = String(req.body?.new_email ?? '').trim().toLowerCase();
    if (!newEmail || !/^.+@.+\..+$/.test(newEmail)) {
      return res.redirect(`/admin/users/${id}?error=invalid_email`);
    }

    // Fetch existing email so we can include it in the audit log.
    const { rows: existing } = await query(
      `SELECT email FROM users WHERE id = $1`,
      [id],
    );
    if (existing.length === 0) {
      return res.status(404).type('html').send(layout({
        title: 'Not found',
        body: '<p>User not found.</p>',
      }));
    }
    const oldEmail = existing[0].email as string | null;

    // Refuse if the new email is already taken (UNIQUE constraint
    // would 500 anyway; surface a clean error).
    const { rows: collision } = await query(
      `SELECT id FROM users WHERE LOWER(email) = $1 AND id <> $2`,
      [newEmail, id],
    );
    if (collision.length > 0) {
      return res.status(409).type('html').send(layout({
        title: 'Email taken',
        body: `<p><strong>${esc(newEmail)}</strong> is already in use by another user.</p>
               <p><a href="/admin/users/${esc(id)}">← Back</a></p>`,
      }));
    }

    const newHash = emailHash(newEmail);
    await query(
      `UPDATE users
         SET email = $1, email_hash = $2, updated_at = NOW()
       WHERE id = $3`,
      [newEmail, newHash, id],
    );

    // Clear pending OTPs for both addresses (same cleanup we did
    // by hand in psql).
    const { rowCount: otpsCleared } = await query(
      `DELETE FROM email_otps WHERE email = ANY($1)`,
      [[oldEmail, newEmail].filter(Boolean)],
    );

    await writeAudit(req, 'change_email', id, {
      from: oldEmail,
      to: newEmail,
      email_hash_recomputed: true,
      email_otps_cleared: otpsCleared ?? 0,
    });

    res.redirect(`/admin/users/${id}`);
  }),
);

adminRouter.post(
  '/users/:id/sessions/revoke',
  adminOnly,
  writeLimit,
  express_urlencoded(),
  asyncHandler(async (req: Request, res: Response) => {
    if (!verifyCsrf(req)) {
      return res.status(403).send('CSRF check failed.');
    }
    const id = String(req.params.id);
    const { rowCount } = await query(
      `UPDATE refresh_tokens
         SET revoked_at = NOW()
       WHERE user_id = $1 AND revoked_at IS NULL`,
      [id],
    );
    await writeAudit(req, 'revoke_sessions', id, {
      sessions_revoked: rowCount ?? 0,
    });
    res.redirect(`/admin/users/${id}`);
  }),
);

adminRouter.post(
  '/users/:id/delete',
  adminOnly,
  writeLimit,
  express_urlencoded(),
  asyncHandler(async (req: Request, res: Response) => {
    if (!verifyCsrf(req)) return res.status(403).send('CSRF check failed.');
    const id = String(req.params.id);
    await query(
      `UPDATE users SET deleted_at = NOW(), updated_at = NOW() WHERE id = $1 AND deleted_at IS NULL`,
      [id],
    );
    await writeAudit(req, 'soft_delete', id, {});
    res.redirect(`/admin/users/${id}`);
  }),
);

adminRouter.post(
  '/users/:id/restore',
  adminOnly,
  writeLimit,
  express_urlencoded(),
  asyncHandler(async (req: Request, res: Response) => {
    if (!verifyCsrf(req)) return res.status(403).send('CSRF check failed.');
    const id = String(req.params.id);
    await query(
      `UPDATE users SET deleted_at = NULL, updated_at = NOW() WHERE id = $1`,
      [id],
    );
    await writeAudit(req, 'restore', id, {});
    res.redirect(`/admin/users/${id}`);
  }),
);

/// Toggle a user's marketing_opt_in flag from the admin user-detail
/// page. Used to honor manual opt-out requests (someone emails you
/// asking to be unsubscribed but doesn't click the email link) or
/// to opt a user back in (no public re-opt-in surface; this is the
/// only path).
adminRouter.post(
  '/users/:id/marketing-opt-in/toggle',
  adminOnly,
  writeLimit,
  express_urlencoded(),
  asyncHandler(async (req: Request, res: Response) => {
    if (!verifyCsrf(req)) return res.status(403).send('CSRF check failed.');
    const id = String(req.params.id);

    // Read current state, flip it, stamp the opt-out timestamp on
    // the way out (and clear it on the way back in).
    const { rows } = await query(
      `SELECT marketing_opt_in FROM users WHERE id = $1`,
      [id],
    );
    if (rows.length === 0) return res.status(404).send('User not found');
    const current = rows[0].marketing_opt_in;
    const next = !current;

    await query(
      `UPDATE users
          SET marketing_opt_in = $1,
              marketing_opted_out_at = CASE
                WHEN $1 = false THEN COALESCE(marketing_opted_out_at, NOW())
                ELSE NULL
              END,
              updated_at = NOW()
        WHERE id = $2`,
      [next, id],
    );
    await writeAudit(req, 'marketing_opt_in_toggle', id, {
      from: current,
      to: next,
    });
    res.redirect(`/admin/users/${id}`);
  }),
);

// ── Broadcast (marketing email blasts via Resend) ──────────────────

adminRouter.get(
  '/broadcast',
  adminOnly,
  asyncHandler(async (req: Request, res: Response) => {
    const { templates, allOptedInRecipients } = await import('../marketing');

    const recipients = await allOptedInRecipients();

    // Recent broadcasts so the operator doesn't accidentally
    // re-fire the same template hours later.
    const { rows: recentBroadcasts } = await query(
      `SELECT b.id, b.template_key, b.subject, b.recipient_count,
              b.send_count, b.failure_count, b.started_at, b.completed_at,
              u.display_name AS initiated_by_name
         FROM broadcasts b
         JOIN users u ON u.id = b.initiated_by_user_id
         ORDER BY b.started_at DESC
         LIMIT 10`,
    );

    const csrf = ensureCsrf(req, res);

    res.type('html').send(layout({
      title: 'Broadcast',
      nav: 'broadcast',
      body: `
        <h1>Broadcast</h1>
        <p class="muted small">
          Templated emails sent through Resend to every opted-in user.
          Distinct from OTP / transactional (those go through
          Postmark — separate sender reputation).
        </p>

        <section class="grid" style="margin-top:24px;">
          <div>
            <div class="label">Audience</div>
            <div>${recipients.length} opted-in user${recipients.length === 1 ? '' : 's'}</div>
          </div>
          <div>
            <div class="label">From</div>
            <div class="small"><code>${esc(processEnv('MARKETING_FROM_EMAIL', config.marketingFromEmail))}</code></div>
          </div>
          <div>
            <div class="label">Resend API key</div>
            <div>${processEnv('RESEND_API_KEY', '') ? '<span class="badge">Configured</span>' : '<span class="badge badge-warn">Not set</span>'}</div>
          </div>
        </section>

        <h2>Send a broadcast</h2>
        <p class="muted small">Each form previews in a new tab; the
          send action runs after a confirm step. There's no scheduled
          sends or undo — once you click send, the queue starts
          immediately.</p>

        ${templates.map((t) => `
          <div style="border:0.5px solid var(--border);border-radius:8px;padding:20px;margin-bottom:16px;background:var(--surface);">
            <div style="display:flex;justify-content:space-between;align-items:start;gap:16px;">
              <div>
                <div style="font-weight:600;font-size:15px;">${esc(t.label)}</div>
                <div class="muted small" style="margin-top:4px;">${esc(t.description)}</div>
                <div class="muted small" style="margin-top:6px;"><code>${esc(t.key)}</code></div>
              </div>
              <div style="display:flex;gap:8px;flex-shrink:0;">
                <a href="/admin/broadcast/preview/${esc(t.key)}" target="_blank" rel="noopener"
                   style="padding:8px 14px;font-size:13px;border:1px solid var(--border);border-radius:6px;color:var(--text);text-decoration:none;background:var(--surface);">
                  Preview
                </a>
                <form method="post" action="/admin/broadcast/send" style="margin:0;display:inline;"
                      onsubmit="return confirm('Send &quot;${esc(t.label)}&quot; to ${recipients.length} user${recipients.length === 1 ? '' : 's'}? This cannot be undone.');">
                  <input type="hidden" name="csrf" value="${csrf}">
                  <input type="hidden" name="template_key" value="${esc(t.key)}">
                  <button type="submit" class="danger" ${recipients.length === 0 ? 'disabled' : ''}>
                    Send to ${recipients.length}
                  </button>
                </form>
              </div>
            </div>
          </div>
        `).join('')}

        <h2>Recent broadcasts</h2>
        <table>
          <thead>
            <tr>
              <th>Sent</th>
              <th>Template</th>
              <th>Subject</th>
              <th>Sent / Failed / Total</th>
              <th>By</th>
            </tr>
          </thead>
          <tbody>
            ${recentBroadcasts.map((b: any) => `
              <tr>
                <td class="small muted">${esc(formatDate(b.completed_at ?? b.started_at))}</td>
                <td><span class="badge">${esc(b.template_key)}</span></td>
                <td class="small">${esc(b.subject)}</td>
                <td class="small">${b.send_count} / ${b.failure_count} / ${b.recipient_count}${b.completed_at ? '' : ' <span class="muted">(running)</span>'}</td>
                <td class="small">${esc(b.initiated_by_name)}</td>
              </tr>
            `).join('')}
            ${recentBroadcasts.length === 0 ? '<tr><td colspan="5" class="muted center">No broadcasts sent yet.</td></tr>' : ''}
          </tbody>
        </table>
      `,
    }));
  }),
);

adminRouter.get(
  '/broadcast/preview/:templateKey',
  adminOnly,
  asyncHandler(async (req: Request, res: Response) => {
    const { findTemplate } = await import('../marketing');
    const t = findTemplate(String(req.params.templateKey));
    if (!t) return res.status(404).send('Unknown template');

    // Render against the admin's own user_id so the unsubscribe
    // token is real (clicking it from the preview will actually
    // opt the admin out — that's intentional, makes the link
    // verifiably correct).
    const adminId = req.user!.userId;
    const { rows } = await query(
      `SELECT display_name FROM users WHERE id = $1`,
      [adminId],
    );
    const previewName = rows[0]?.display_name ?? 'Admin';

    const rendered = t.render({
      recipientUserId: adminId,
      recipientName: previewName,
    });
    res.type('html').send(rendered.html);
  }),
);

adminRouter.post(
  '/broadcast/send',
  adminOnly,
  writeLimit,
  express_urlencoded(),
  asyncHandler(async (req: Request, res: Response) => {
    if (!verifyCsrf(req)) return res.status(403).send('CSRF check failed.');
    const { sendBroadcast } = await import('../marketing');

    const templateKey = String(req.body?.template_key ?? '');
    if (!templateKey) return res.status(400).send('template_key required');

    try {
      const result = await sendBroadcast({
        templateKey,
        initiatedByUserId: req.user!.userId,
      });
      await writeAudit(req, 'broadcast_sent', null, {
        template_key: templateKey,
        broadcast_id: result.broadcastId,
        recipient_count: result.recipientCount,
        send_count: result.sendCount,
        failure_count: result.failureCount,
      });
      res.redirect('/admin/broadcast');
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      res.status(500).type('html').send(layout({
        title: 'Broadcast failed',
        nav: 'broadcast',
        body: `
          <h1>Broadcast failed</h1>
          <p>${esc(msg)}</p>
          <p><a href="/admin/broadcast">← Back</a></p>
        `,
      }));
    }
  }),
);

// Tiny helper so the broadcast page can show "RESEND_API_KEY is
// configured" without leaking the value. Reads straight from
// process.env (not config.ts) so the badge reflects current state
// even if the prod env was just updated.
function processEnv(name: string, fallback: string): string {
  return process.env[name] || fallback;
}

adminRouter.get(
  '/audit',
  adminOnly,
  asyncHandler(async (_req: Request, res: Response) => {
    const { rows } = await query(
      `SELECT a.id, a.action, a.target_user_id, a.details, a.ip_address,
              a.created_at,
              admin.email AS admin_email, admin.display_name AS admin_name,
              target.email AS target_email, target.display_name AS target_name
         FROM admin_audit a
         JOIN users admin ON admin.id = a.admin_user_id
         LEFT JOIN users target ON target.id = a.target_user_id
         ORDER BY a.created_at DESC
         LIMIT 200`,
    );

    res.type('html').send(layout({
      title: 'Audit log',
      nav: 'audit',
      body: `
        <h1>Audit log</h1>
        <p class="muted small">Last 200 admin mutations, newest first.</p>
        <table>
          <thead>
            <tr>
              <th>When</th>
              <th>Admin</th>
              <th>Action</th>
              <th>Target</th>
              <th>Details</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map((r) => `
              <tr>
                <td class="small muted">${esc(formatDate(r.created_at))}</td>
                <td>${esc(r.admin_name)}</td>
                <td><span class="badge">${esc(r.action)}</span></td>
                <td>${r.target_user_id ? `<a href="/admin/users/${esc(r.target_user_id)}">${esc(r.target_name ?? r.target_email ?? r.target_user_id)}</a>` : '<span class="muted">—</span>'}</td>
                <td class="small muted"><code>${esc(JSON.stringify(r.details))}</code></td>
              </tr>
            `).join('')}
            ${rows.length === 0 ? '<tr><td colspan="5" class="muted center">No mutations yet.</td></tr>' : ''}
          </tbody>
        </table>
      `,
    }));
  }),
);

// ── HTML helpers ────────────────────────────────────────────────────

interface LayoutOpts {
  title: string;
  body: string;
  nav?: 'users' | 'broadcast' | 'audit';
}

function layout({ title, body, nav }: LayoutOpts): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>${esc(title)} · A/SIDE admin</title>
  <style>${ADMIN_CSS}</style>
</head>
<body>
  <header>
    <div class="brand"><a href="/admin/users">A/SIDE admin</a></div>
    <nav>
      <a class="${nav === 'users' ? 'active' : ''}" href="/admin/users">Users</a>
      <a class="${nav === 'broadcast' ? 'active' : ''}" href="/admin/broadcast">Broadcast</a>
      <a class="${nav === 'audit' ? 'active' : ''}" href="/admin/audit">Audit</a>
      <form method="post" action="/admin/logout" class="logout">
        <button type="submit" class="link">Sign out</button>
      </form>
    </nav>
  </header>
  <main>
    ${body}
  </main>
</body>
</html>`;
}

const ADMIN_CSS = `
  :root {
    --bg: #FBFAF7;
    --surface: #fff;
    --text: #1a1719;
    --muted: #7a7578;
    --tertiary: #a8a3a6;
    --border: #e6e3df;
    --accent: #4a4a6e;
    --warn: #b85a3e;
    --danger: #b8403a;
    --success: #4a7a4a;
  }
  * { box-sizing: border-box; }
  html { font-size: 15px; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    line-height: 1.5;
  }
  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 16px 32px;
    border-bottom: 0.5px solid var(--border);
    background: var(--surface);
    position: sticky; top: 0; z-index: 1;
  }
  header .brand a {
    font-family: Georgia, serif;
    font-size: 20px;
    font-weight: 600;
    color: var(--text);
    text-decoration: none;
  }
  header nav { display: flex; gap: 24px; align-items: center; }
  header nav a {
    color: var(--muted);
    text-decoration: none;
    font-size: 14px;
    padding: 6px 0;
    border-bottom: 2px solid transparent;
  }
  header nav a:hover, header nav a.active {
    color: var(--text);
    border-bottom-color: var(--text);
  }
  header .logout { display: inline; }
  button.link {
    background: none; border: 0; padding: 0; cursor: pointer;
    color: var(--muted); font-size: 14px; font-family: inherit;
  }
  button.link:hover { color: var(--text); }
  main {
    max-width: 960px;
    margin: 0 auto;
    padding: 32px;
  }
  h1 { font-family: Georgia, serif; font-size: 28px; font-weight: 600; margin: 0 0 8px; letter-spacing: -0.01em; }
  h2 { font-size: 16px; font-weight: 600; margin: 32px 0 8px; }
  p { margin: 8px 0; }
  .muted { color: var(--muted); }
  .small { font-size: 13px; }
  .center { text-align: center; }
  .breadcrumb { font-size: 13px; }
  .breadcrumb a { color: var(--muted); text-decoration: none; }
  .breadcrumb a:hover { color: var(--text); }
  code { font-family: 'SF Mono', ui-monospace, monospace; font-size: 13px; background: rgba(0,0,0,0.04); padding: 2px 5px; border-radius: 3px; }
  table { width: 100%; border-collapse: collapse; margin: 16px 0; }
  th, td { padding: 10px 12px; text-align: left; border-bottom: 0.5px solid var(--border); }
  th { font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); font-weight: 500; }
  tbody tr:nth-child(even) { background: rgba(0,0,0,0.012); }
  tbody tr.deleted { opacity: 0.5; }
  tbody tr a { color: var(--text); text-decoration: none; }
  tbody tr a:hover { text-decoration: underline; }
  .badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 500;
    background: rgba(74, 122, 74, 0.12);
    color: var(--success);
  }
  .badge-warn { background: rgba(184, 90, 62, 0.12); color: var(--warn); }
  .grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 16px;
    background: var(--surface);
    border: 0.5px solid var(--border);
    border-radius: 8px;
    padding: 20px;
    margin: 20px 0;
  }
  .grid .label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); margin-bottom: 4px; }
  form { margin: 8px 0 16px; }
  form label { display: block; margin-bottom: 12px; font-size: 13px; color: var(--muted); }
  form label input { display: block; width: 100%; max-width: 400px; padding: 8px 12px; font-size: 14px; border: 1px solid var(--border); border-radius: 6px; background: var(--surface); margin-top: 4px; font-family: inherit; }
  form label input:focus { outline: 2px solid var(--accent); outline-offset: -1px; border-color: var(--accent); }
  form button {
    padding: 8px 16px; font-size: 14px; font-weight: 500;
    background: var(--text); color: var(--surface);
    border: 1px solid var(--text); border-radius: 6px; cursor: pointer; font-family: inherit;
  }
  form button:hover { opacity: 0.85; }
  form button.danger { background: transparent; color: var(--danger); border-color: var(--danger); }
  form button.danger:hover { background: var(--danger); color: var(--surface); }
  form.search { display: flex; gap: 8px; align-items: center; margin: 16px 0; }
  form.search input { flex: 1; max-width: 480px; padding: 8px 12px; font-size: 14px; border: 1px solid var(--border); border-radius: 6px; background: var(--surface); }
  form.search button { padding: 8px 14px; }
  form.search a { color: var(--muted); font-size: 13px; text-decoration: none; }
`;

function planLabel(plan: string | null, status: string): string {
  if (status !== 'active' && status !== 'trial') return 'Free';
  if (plan === 'pro_family') return 'Pro Family';
  if (plan === 'pro_individual' || plan === 'pro') return 'Pro';
  return 'Pro';
}

function formatDate(d: Date | string | null): string {
  if (!d) return '—';
  const date = typeof d === 'string' ? new Date(d) : d;
  return date.toLocaleString('en-US', {
    year: 'numeric', month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });
}

// Local body parser specifically for form submissions. Express has
// already wired express.json() globally in app.ts, but the admin
// forms post `application/x-www-form-urlencoded` which json() doesn't
// touch. Adding a per-route urlencoded() parser keeps the global
// middleware lean (the rest of the API is JSON-only).
function express_urlencoded() {
  return (require('express').urlencoded as typeof import('express').urlencoded)({ extended: false });
}
