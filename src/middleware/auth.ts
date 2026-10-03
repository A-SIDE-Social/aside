import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { config } from '../config';
import { query } from '../db/pool';
import type { FailureAuthResult } from '../performance';

export interface AuthPayload {
  userId: string;
}

declare global {
  namespace Express {
    interface Request {
      user?: AuthPayload;
    }
  }
}

export async function activeUserExists(userId: string): Promise<boolean> {
  const { rows } = await query(
    'SELECT 1 FROM users WHERE id = $1 AND deleted_at IS NULL',
    [userId],
  );
  return rows.length > 0;
}

export async function authenticate(
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> {
  const setAuthResult = (result: FailureAuthResult) => {
    res.locals.authResult = result;
    if (result !== 'accepted') res.locals.failureStage = 'auth';
  };
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    setAuthResult('missing_or_malformed');
    res.status(401).json({ error: 'Missing or invalid authorization header' });
    return;
  }

  const token = header.slice(7);
  let payload: AuthPayload;
  try {
    payload = jwt.verify(token, config.jwtSecret) as AuthPayload;
  } catch {
    setAuthResult('invalid_or_expired');
    res.status(401).json({ error: 'Invalid or expired token' });
    return;
  }

  try {
    if (!(await activeUserExists(payload.userId))) {
      setAuthResult('inactive_account');
      res.status(401).json({ error: 'Account is no longer active' });
      return;
    }
    setAuthResult('accepted');
    req.user = payload;
    next();
  } catch (err) {
    next(err);
  }
}

export function generateAccessToken(userId: string): string {
  return jwt.sign({ userId }, config.jwtSecret, { expiresIn: config.jwtExpiresIn } as jwt.SignOptions);
}

export function generateRefreshToken(userId: string): string {
  return jwt.sign({ userId }, config.jwtRefreshSecret, { expiresIn: config.refreshTokenExpiresIn } as jwt.SignOptions);
}
