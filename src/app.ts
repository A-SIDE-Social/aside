import express from 'express';
import cors from 'cors';
import cookieParser from 'cookie-parser';
import { config } from './config';
import { standardLimit } from './middleware/rateLimit';
import { errorHandler } from './middleware/errorHandler';
import { router } from './routes';
import { adminRouter } from './routes/admin';
import { unsubscribeRouter } from './routes/unsubscribe';
import { serveOpenApiDocs } from './openapi';

export const app = express();

app.set('trust proxy', 1);
app.use(cors());
// Cookie parser used only by /admin (the API auth uses Bearer
// headers). Signing key reuses the JWT secret since both are
// existing operator-controlled secrets — no second env var to
// rotate. Mounted globally so the admin router can read signed
// cookies without further setup.
app.use(cookieParser(config.jwtSecret));
// JSON limit raised to 5 MB so the contact-sync endpoint can
// accept users with normal-sized address books. Default Express
// limit is 100 KB, which holds ~1,400 SHA-256 hashes — anyone
// with more contacts than that hits PayloadTooLargeError on
// POST /v1/contacts/sync. The route caps internally at 5,000
// hashes (~350 KB), so 5 MB is generous headroom.
app.use(express.json({ limit: '5mb' }));
app.use(express.raw({ type: ['image/*', 'video/*'], limit: '50mb' }));
if (config.nodeEnv !== 'test') {
  app.use(standardLimit);
}

serveOpenApiDocs(app);
app.use('/v1', router);
// Admin web UI. Single-operator dashboard for quick fixes; gated
// by the ADMIN_USER_IDS env var allowlist + OTP auth. See
// src/routes/admin.ts.
app.use('/admin', adminRouter);
// Public, no-auth unsubscribe endpoint reached from the footer
// of marketing broadcast emails. Token-signed (HMAC) so anyone
// with the link can act on it without an active session.
app.use('/unsubscribe', unsubscribeRouter);

app.get('/health', (_req, res) => {
  res.json({ status: 'ok' });
});

app.use(errorHandler);
