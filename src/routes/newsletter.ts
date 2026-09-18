import { Router, Request, Response, urlencoded } from 'express';
import rateLimit from 'express-rate-limit';
import { newsletterConfig } from '../newsletter/config';
import { confirmSignup, escapeHtml, normalizeEmail, requestSignup, validToken } from '../newsletter/service';

export const newsletterRouter = Router();
newsletterRouter.use(urlencoded({ extended: false, limit: '4kb' }));
newsletterRouter.use((_req, res, next) => {
  res.set({ 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Robots-Tag': 'noindex, nofollow',
    'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'" });
  next();
});

function page(res: Response, status: number, title: string, message: string, extra = '') {
  const site = newsletterConfig()?.siteUrl;
  return res.status(status).type('html').send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)} · A/SIDE Notes</title></head><body style="margin:0;background:#f3ecde;color:#1a1814;font:17px/1.6 -apple-system,BlinkMacSystemFont,sans-serif"><main style="max-width:540px;margin:10vh auto;padding:24px"><p>A/SIDE Notes</p><h1 style="font-size:32px;line-height:1.15">${escapeHtml(title)}</h1><p>${escapeHtml(message)}</p>${extra}${site ? `<p><a style="color:inherit" href="${escapeHtml(site)}/notes">Back to Notes</a></p>` : ''}</main></body></html>`);
}

const limited = () => rateLimit({ windowMs: 60 * 60 * 1000, limit: 5, standardHeaders: 'draft-8', legacyHeaders: false,
  skip: () => process.env.NODE_ENV === 'test',
  handler: (_req, res) => page(res, 429, 'Please try again later.', 'There have been several signup attempts from your connection. Try again in an hour.'),
});
const globalLimit = rateLimit({ windowMs: 60 * 60 * 1000, limit: 100, keyGenerator: () => 'newsletter',
  skip: () => process.env.NODE_ENV === 'test', standardHeaders: 'draft-8', legacyHeaders: false,
  handler: (_req, res) => page(res, 429, 'Please try again later.', 'Signups are busy right now. Please try again in an hour.'),
});

function allowedOrigin(req: Request, confirmation = false) {
  const settings = newsletterConfig();
  return settings && typeof req.headers.origin === 'string' &&
    [...settings.origins, ...(confirmation ? [settings.apiUrl] : [])].includes(req.headers.origin);
}

newsletterRouter.post('/subscribe', limited(), globalLimit, async (req, res) => {
  const settings = newsletterConfig();
  if (!settings) { page(res, 503, 'Email signup is unavailable.', 'Please try again later.'); return; }
  if (!allowedOrigin(req)) { page(res, 403, 'Please use the signup form.', 'Open the Notes page and try again.'); return; }
  if (req.body?.website) { page(res, 200, 'Check your inbox.', 'Look for an email from A/SIDE Notes and confirm your subscription.'); return; }
  const email = normalizeEmail(req.body?.email);
  if (!email || req.body?.consent !== 'yes') {
    page(res, 400, 'Check the signup form.', 'Enter a valid email address and choose to receive A/SIDE Notes.'); return;
  }
  try {
    await requestSignup(email, settings);
    page(res, 200, 'Check your inbox.', 'Look for an email from A/SIDE Notes and confirm your subscription. If you recently requested a link, use that email or try again in 15 minutes.');
  } catch {
    console.warn('Newsletter confirmation email could not be sent');
    page(res, 503, 'We couldn’t send the email.', 'Please try again in 15 minutes.');
  }
});

newsletterRouter.get('/confirm', (req, res) => {
  if (!newsletterConfig()) { page(res, 503, 'Email signup is unavailable.', 'Please try again later.'); return; }
  if (!validToken(req.query.token)) { page(res, 400, 'This link isn’t valid.', 'Request a new link from the Notes page.'); return; }
  // GET is deliberately read-only: email security scanners must not subscribe people.
  page(res, 200, 'One more click.', 'Confirm that you’d like occasional A/SIDE Notes emails. You can unsubscribe anytime.',
    `<form method="post" action="/newsletter/confirm"><input type="hidden" name="token" value="${req.query.token}"><button style="border:0;border-radius:24px;padding:14px 24px;background:#1a1814;color:#fff;font:inherit" type="submit">Confirm my subscription</button></form>`);
});

newsletterRouter.post('/confirm', limited(), async (req, res) => {
  const settings = newsletterConfig();
  if (!settings) { page(res, 503, 'Email signup is unavailable.', 'Please try again later.'); return; }
  if (!allowedOrigin(req, true) || !validToken(req.body?.token)) {
    page(res, 400, 'This link isn’t valid.', 'Request a new link from the Notes page.'); return;
  }
  try {
    const outcome = await confirmSignup(req.body.token, settings);
    if (outcome === 'invalid') { page(res, 400, 'This link has expired.', 'Request a new link from the Notes page.'); return; }
    if (outcome === 'used') { page(res, 200, 'This link has already been used.', 'Your email preferences haven’t changed. To subscribe again, request a new link from the Notes page.'); return; }
    if (outcome === 'unsubscribed') {
      page(res, 409, 'Your unsubscribe preference is still in place.', 'This address has opted out of all our emails. Reply to the confirmation email if you’d like help subscribing only to Notes.'); return;
    }
    page(res, 200, 'You’re subscribed.', 'The next A/SIDE Notes will arrive in your inbox. In the meantime, you can read the latest issue on the website.',
      `<p><a style="color:inherit" href="${escapeHtml(settings.siteUrl)}/blog">Read the latest notes →</a></p>`);
  } catch {
    console.warn('Newsletter subscription could not be activated');
    page(res, 503, 'We couldn’t confirm that just yet.', 'Your link still works. Please wait a moment and try again.');
  }
});
