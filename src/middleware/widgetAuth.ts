import crypto from 'crypto';
import jwt from 'jsonwebtoken';
import { Request, Response, NextFunction } from 'express';
import { config } from '../config';
import { query } from '../db/pool';
import { authenticate } from './auth';
import { asyncHandler } from '../helpers';
import { AppError } from './errorHandler';

// A separate signing key prevents a widget credential from authenticating to
// messages, uploads, account settings, the normal feed or any other API route.
const key = () => crypto.createHmac('sha256', config.jwtSecret).update('aside-widget-photo-v1').digest();
const audience = 'aside-widget-photo';

export const createWidgetSession = asyncHandler(async (req: any, res: any) => {
  const credential = req.body.refresh_token;
  if (typeof credential !== 'string' || !credential || credential.length > 4096) {
    throw new AppError(400, 'Current session is required');
  }
  const fingerprint = crypto.createHash('sha256').update(credential).digest('hex');
  const { rows } = await query(`SELECT id FROM refresh_tokens
    WHERE token_hash = $1 AND user_id = $2 AND revoked_at IS NULL
      AND expires_at > clock_timestamp()`, [fingerprint, req.user!.userId]);
  // A rotation racing this request should be retried with the newly saved
  // credential, without signing the user out or consuming any refresh token.
  if (!rows.length) throw new AppError(409, 'Open the app to refresh the current session');
  const token = jwt.sign({ userId: req.user!.userId, sessionId: rows[0].id, scope: 'widget-photo' }, key(), {
    algorithm: 'HS256', audience, expiresIn: '30d',
  });
  res.set('Cache-Control', 'private, no-store').json({ token });
});

export async function authenticateWidget(req: Request, res: Response, next: NextFunction) {
  const bearer = req.headers.authorization?.startsWith('Bearer ') ? req.headers.authorization.slice(7) : '';
  let payload: jwt.JwtPayload;
  try {
    const decoded = jwt.verify(bearer, key(), { algorithms: ['HS256'], audience });
    if (typeof decoded === 'string' || decoded.scope !== 'widget-photo' ||
        typeof decoded.userId !== 'string' || typeof decoded.sessionId !== 'string') throw new Error('Invalid widget credential');
    payload = decoded;
  } catch {
    // The containing app can also use its ordinary access token on this one
    // read endpoint. Widget credentials are never accepted by authenticate().
    return authenticate(req, res, next);
  }
  try {
    const { rows } = await query(`SELECT 1 FROM refresh_tokens rt JOIN users u ON u.id=rt.user_id
      WHERE rt.id=$1 AND rt.user_id=$2 AND rt.revoked_at IS NULL
        AND rt.expires_at > clock_timestamp() AND u.deleted_at IS NULL`, [payload.sessionId, payload.userId]);
    if (!rows.length) {
      res.locals.authResult = 'invalid_or_expired'; res.locals.failureStage = 'auth';
      res.status(401).json({ error: 'Open A/SIDE to refresh your widget' }); return;
    }
    res.locals.authResult = 'accepted'; req.user = { userId: payload.userId };
    next();
  } catch (error) { next(error); }
}
