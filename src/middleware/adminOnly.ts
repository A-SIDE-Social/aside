import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { config } from '../config';
import type { AuthPayload } from './auth';

/// The cookie name carrying the admin's JWT. Set on successful
/// admin login, cleared on logout. Verified on every protected
/// route by `adminOnly`.
export const ADMIN_COOKIE = 'admin_session';

/// Gates HTML routes under /admin/* (other than the login pages).
///
/// Belt-and-suspenders defense:
///   1. Cookie present? If not → redirect to /admin/login.
///   2. JWT signature valid? If not → redirect to /admin/login.
///   3. user_id in `config.adminUserIds` allowlist? If not → 403.
///
/// The allowlist is checked at *every* request rather than just at
/// login: removing a user_id from `ADMIN_USER_IDS` and restarting
/// the server immediately revokes admin access on the next
/// request, even if the cookie is still within its 1h expiry.
/// Pull the env var → bounce the container → admin is locked out.
export function adminOnly(
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  const token = req.signedCookies?.[ADMIN_COOKIE];
  if (!token) {
    res.redirect('/admin/login');
    return;
  }

  let payload: AuthPayload;
  try {
    payload = jwt.verify(token, config.jwtSecret) as AuthPayload;
  } catch {
    // Bad signature, expired, or otherwise tampered. Clear the
    // cookie so the user gets a clean login slot rather than
    // looping on a stale value.
    res.clearCookie(ADMIN_COOKIE);
    res.redirect('/admin/login');
    return;
  }

  if (!config.adminUserIds.includes(payload.userId)) {
    // The cookie's JWT is valid but this user_id was removed from
    // the allowlist. Don't redirect to login (they'd just bounce
    // back here) — render a 403 so the operator sees the explicit
    // denial.
    res.status(403).type('html').send(
      '<!doctype html><html><body style="font-family:system-ui;padding:32px">' +
        '<h1>Access denied</h1>' +
        '<p>Your user is not in the admin allowlist.</p>' +
        '<p><a href="/admin/logout">Sign out</a></p>' +
        '</body></html>',
    );
    return;
  }

  req.user = payload;
  next();
}

/// Cookie options used for the admin session. Exported so the
/// login + logout handlers stay in lockstep with the middleware
/// reader (any change to the cookie shape lands in one place).
export const adminCookieOptions = {
  httpOnly: true as const,
  secure: config.nodeEnv === 'production',
  sameSite: 'strict' as const,
  signed: true as const,
  // 1 hour. Short enough that a compromised laptop's exposure
  // window is bounded; long enough that a normal admin session
  // doesn't constantly re-auth.
  maxAge: 60 * 60 * 1000,
  path: '/admin',
};
