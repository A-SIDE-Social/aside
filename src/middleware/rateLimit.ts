import rateLimit, { ipKeyGenerator } from 'express-rate-limit';
import { RequestHandler } from 'express';

const isDev = process.env.NODE_ENV === 'development';
const isTest = process.env.NODE_ENV === 'test';

const noop: RequestHandler = (_req, _res, next) => next();

export const standardLimit: RequestHandler = isTest
  ? noop
  : rateLimit({
      windowMs: 60 * 1000,
      // 5 req/sec — generous enough that a normal session (pull-to-refresh,
      // app resume, parallel avatar/post fetches) doesn't trip it, while still
      // capping abuse. The bucket is per-IP, so users behind a NAT share it.
      max: 300,
      standardHeaders: true,
      legacyHeaders: false,
      validate: { trustProxy: false },
      message: { error: 'Too many requests, please try again later' },
    });

export const writeLimit: RequestHandler = isTest
  ? noop
  : rateLimit({
      windowMs: 60 * 1000,
      max: isDev ? 100 : 30,
      standardHeaders: true,
      legacyHeaders: false,
      validate: { trustProxy: false },
      message: { error: 'Too many requests, please try again later' },
    });

// Auth limit. The bucket is per-IP, and a single user-facing sign-in
// attempt burns two slots (POST /request-otp + POST /verify-otp), so
// the effective ceiling is `max / 2` end-to-end attempts per window.
// 10/15min was 5 attempts — tight enough that one OTP typo on a
// shared NAT (family wifi, office) could lock everyone out. 50/15min
// gives ~25 end-to-end attempts, still well below brute-force range
// for a 6-digit OTP and the per-OTP db constraints (1 unused code at
// a time per email + 30s cooldown per email enforced separately in
// the request-otp handler).
export const authLimit: RequestHandler = isTest
  ? noop
  : rateLimit({
      windowMs: 15 * 60 * 1000,
      max: isDev ? 200 : 50,
      standardHeaders: true,
      legacyHeaders: false,
      validate: { trustProxy: false },
      message: { error: 'Too many attempts, please try again later' },
    });

export const inviteValidateLimit: RequestHandler = isTest
  ? noop
  : rateLimit({
      windowMs: 15 * 60 * 1000,
      max: isDev ? 50 : 5,
      standardHeaders: true,
      legacyHeaders: false,
      validate: { trustProxy: false },
      message: { error: 'Too many attempts, please try again later' },
    });

// Per-user bucket for GET /v1/users/:id/keybundle. Each request
// consumes one of the target user's one-time prekeys, so an abusive
// caller could exhaust a victim's OTPK supply quickly without a cap.
// 60/hour per *requester* is the plan's chosen ceiling — enough for
// normal session setup with many peers on a busy day, and the
// replenish threshold (20) means a victim still has headroom before
// falling back to the last-resort no-OTPK X3DH path.
export const keyBundleLimit: RequestHandler = isTest
  ? noop
  : rateLimit({
      windowMs: 60 * 60 * 1000,
      max: isDev ? 500 : 60,
      keyGenerator: (req, res) => (req as any).user?.userId ?? ipKeyGenerator(req.ip ?? '', false),
      standardHeaders: true,
      legacyHeaders: false,
      validate: { trustProxy: false },
      message: { error: 'Too many keybundle fetches, please try again later' },
    });

// Per-user bucket for GET /v1/users/by-slug/:slug. The endpoint
// returns minimal payload (id + display_name + avatar_url) for the
// in-app "Send request to [Name]?" confirmation screen. We rate-limit
// hard to stop slug-space enumeration: someone scripting a brute-
// force search for friends would burn this limit within seconds.
// 20/min is generous enough for legitimate tap-link flows (typical
// user opens 1–2 send-request screens per session) but tight enough
// that enumeration is infeasible.
export const usernameLookupLimit: RequestHandler = isTest
  ? noop
  : rateLimit({
      windowMs: 60 * 1000,
      max: isDev ? 200 : 20,
      keyGenerator: (req, res) => (req as any).user?.userId ?? ipKeyGenerator(req.ip ?? '', false),
      standardHeaders: true,
      legacyHeaders: false,
      validate: { trustProxy: false },
      message: { error: 'Too many lookups, please try again later' },
    });

// Per-user bucket for POST /v1/invite-link/regenerate. Rotating a
// slug invalidates every URL and QR the user has shared. Heavy
// rotation is the kind of behavior that suggests either confusion
// ("did it work? let me try again") or abuse (trying to grief
// pending recipients). 10/day per user is the plan's ceiling —
// well above the legitimate "I leaked my QR, rotate now" event
// rate, well below noise.
export const regenerateLimit: RequestHandler = isTest
  ? noop
  : rateLimit({
      windowMs: 24 * 60 * 60 * 1000,
      max: isDev ? 100 : 10,
      keyGenerator: (req, res) => (req as any).user?.userId ?? ipKeyGenerator(req.ip ?? '', false),
      standardHeaders: true,
      legacyHeaders: false,
      validate: { trustProxy: false },
      message: { error: 'Too many regenerations, please try again later' },
    });
