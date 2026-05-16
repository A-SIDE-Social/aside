// Public, no-auth unsubscribe endpoint reached from the footer
// of every marketing broadcast email.
//
// GET  /unsubscribe?token=...  — renders a confirmation page +
//                                lets the click be the action
//                                (one-click semantics for
//                                Gmail / Apple Mail's native
//                                unsubscribe button).
// POST /unsubscribe            — same action, used by the
//                                List-Unsubscribe-Post header so
//                                modern clients can unsubscribe
//                                without rendering the page.
//
// Token: HMAC-signed user_id (see src/marketing/unsubscribe-token.ts).
// Stateless verification — no DB lookup needed to validate; the DB
// write is just the marketing_opt_in flip.

import { Router, Request, Response, urlencoded } from 'express';
import { query } from '../db/pool';
import { asyncHandler } from '../helpers';
import { verifyUnsubscribeToken } from '../marketing/unsubscribe-token';

export const unsubscribeRouter = Router();

// The List-Unsubscribe-Post header tells email clients to issue
// `application/x-www-form-urlencoded` POSTs with `List-Unsubscribe=One-Click`
// in the body. The global JSON parser doesn't handle that — opt
// the POST handler into urlencoded parsing on its own.
const formBody = urlencoded({ extended: false });

const BG = '#FBFAF7';
const TEXT = '#1A1719';
const MUTED = '#7A7578';

function renderPage(opts: { title: string; message: string }): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>${opts.title} · A/SIDE</title>
</head>
<body style="margin:0;padding:0;background:${BG};color:${TEXT};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
  <div style="max-width:480px;margin:0 auto;padding:96px 24px;text-align:center;">
    <div style="font-family:Georgia,'Times New Roman',serif;font-style:italic;font-size:18px;letter-spacing:0.04em;margin-bottom:48px;">A/SIDE</div>
    <h1 style="margin:0 0 16px;font-family:Georgia,'Times New Roman',serif;font-weight:600;font-size:30px;letter-spacing:-0.01em;line-height:1.2;">${opts.title}</h1>
    <p style="margin:0;font-size:16px;line-height:1.6;color:${MUTED};">${opts.message}</p>
  </div>
</body>
</html>`;
}

async function handleUnsubscribe(req: Request, res: Response): Promise<void> {
  const token = String(
    req.query.token ?? req.body?.token ?? '',
  );
  const userId = verifyUnsubscribeToken(token);
  if (!userId) {
    res.status(400).type('html').send(
      renderPage({
        title: 'Link expired or invalid.',
        message:
          "If you got here from a recent email, try the link again. " +
          "Otherwise reply to the email you got and we'll handle it manually.",
      }),
    );
    return;
  }

  const { rows } = await query(
    `UPDATE users
        SET marketing_opt_in = false,
            marketing_opted_out_at = COALESCE(marketing_opted_out_at, NOW())
      WHERE id = $1 AND deleted_at IS NULL
      RETURNING email`,
    [userId],
  );

  if (rows.length === 0) {
    // User was deleted, or token is for a non-existent user_id.
    // Same generic page either way — don't enumerate.
    res.status(200).type('html').send(
      renderPage({
        title: "You're unsubscribed.",
        message: "You won't get marketing emails from us anymore.",
      }),
    );
    return;
  }

  res.status(200).type('html').send(
    renderPage({
      title: "You're unsubscribed.",
      message:
        "You won't get marketing emails from us anymore. " +
        "Account-related emails (verification codes, security alerts) " +
        "will still come through.",
    }),
  );
}

unsubscribeRouter.get('/', asyncHandler(handleUnsubscribe));
unsubscribeRouter.post('/', formBody, asyncHandler(handleUnsubscribe));
