# Marketing Broadcasts

This module implements operator-controlled email broadcasts to opted-in
users. It is optional; if `RESEND_API_KEY` is unset, the admin UI shows
that broadcasts are not configured.

## Architecture

```text
src/marketing/
  unsubscribe-token.ts   HMAC-signed user_id tokens
  audience.ts            opted-in recipients with email addresses
  templates/             one renderer file per template
  send.ts                render, send through Resend, record outcome
  index.ts               re-exports

src/routes/unsubscribe.ts   public GET/POST /unsubscribe
src/routes/admin.ts         /admin/broadcast preview + send surface
src/db/migrations/024_marketing_broadcasts.sql
```

The open-source distribution ships with no product-specific broadcast
templates. Add your own under `src/marketing/templates/` and register
them in `templates/index.ts`.

## Required Env

```text
RESEND_API_KEY=re_...
MARKETING_FROM_EMAIL=broadcasts@example.com
MARKETING_REPLY_TO_EMAIL=support@example.com
UNSUBSCRIBE_BASE_URL=https://api.example.com/unsubscribe
```

Use a verified sending domain in Resend. Keep broadcast mail on a
separate subdomain from transactional OTP mail if you want reputation
isolation.

## Template Rules

- Return `{ subject, html, text }`.
- Render per recipient so each email can include a per-user
  unsubscribe URL.
- Keep styles inline for email-client compatibility.
- Always include a plain-text body.

`send.ts` handles `List-Unsubscribe` headers and records counts in the
`broadcasts` table.
