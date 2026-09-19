# A/SIDE Notes email signup

Notes subscriptions are separate from app accounts and `marketing_opt_in`.
Do not import app users or Substack subscribers. New readers explicitly choose
Notes on the website, receive a confirmation email, and press a confirmation
button before the API adds them to the Resend segment and topic.

## Configure and deploy

1. Create a Resend segment and a private topic called **A/SIDE Notes**. The
   topic's default subscription must be **opt_out** (explicit opt-in required).
   Private visibility keeps it out of unrelated contacts' preference pages.
2. Provision a separate server-only Resend key with Contacts access. A send-only
   key cannot manage subscriptions. Keep the existing `RESEND_API_KEY` for
   confirmation delivery. Never put either key in the website or repository.
3. Set these API-server environment variables:

   ```dotenv
   NEWSLETTER_RESEND_API_KEY=<secret>
   NEWSLETTER_SEGMENT_ID=<segment UUID>
   NEWSLETTER_TOPIC_ID=<topic UUID>
   NEWSLETTER_API_URL=https://api.shopseen.com
   PUBLIC_APP_URL=https://a-side.social
   NEWSLETTER_ALLOWED_ORIGINS=https://a-side.social,https://www.a-side.social
   NEWSLETTER_FROM_EMAIL=Adeel at A/SIDE <notes@a-side.social>
   NEWSLETTER_REPLY_TO_EMAIL=adeel.rb@gmail.com
   NEWSLETTER_POSTAL_ADDRESS=Lab 1908, 1908 Selby Ave., Saint Paul, MN 55104
   ```

4. Build the API image and run the standard migration command, including additive
   migration `029_newsletter_signups`. Start the updated API only after migration
   success. Missing newsletter configuration leaves the routes unavailable (503)
   without preventing the rest of the app from starting.
5. Verify signup with an operator-owned test address. Confirm that GETting the
   email link creates no contact; POSTing the confirmation adds only Notes.
   Verify segment membership and explicit topic opt-in in Resend.
6. Deploy the website `/notes` form only after that end-to-end check succeeds.

The website submits a normal HTML form to `/newsletter/subscribe` on the API.
The hosted app currently uses `api.shopseen.com`; it is the existing A/SIDE
API hostname, not an additional service. Verify the active host before deployment.
It needs no Resend credentials and no JavaScript for signup. Both website origins
must be allowed; confirmation POSTs also allow the API's own origin.

## Sending an issue

Every Notes broadcast must select **both the A/SIDE Notes segment and topic**.
The topic is what gives subscribers a Notes-specific unsubscribe preference.
Keep the working Resend `{{{RESEND_UNSUBSCRIBE_URL}}}` link and business mailing
address in the footer. Keep open/click tracking off. Preview, check the audience,
and send a test before a user-authorized audience send. Do not use the older
app-account broadcast command to send Notes.

Resend is the source of truth for current unsubscribe preferences. The local
table records confirmation, not present eligibility to receive a broadcast.
No unsubscribe webhook or list synchronization job is needed for this flow.
An existing global unsubscribe is never cleared by the signup API; the reader
is invited to reply for help instead. Other topics, properties and segments are
not changed. A fresh confirmation can explicitly opt back into the Notes topic.

## Abuse, privacy and failure behavior

- Only a SHA-256 hash of the random 256-bit confirmation token is stored. Links
  expire in 24 hours. GET is read-only so link scanners cannot subscribe readers.
- A used link cannot subscribe again, including after a later unsubscribe.
  Concurrent confirmations are serialized by a database row lock.
- Confirmation requests have a 15-minute per-email cooldown and a limit of three
  per 24-hour window. Responses do not disclose existing membership.
- Public requests also have in-memory per-connection limits and an hourly
  signup cap. The current deployment runs one API process; multiple replicas
  would need a shared rate-limit store. IPs are not stored in the consent table.
- Unconfirmed requests older than seven days are removed on startup, hourly,
  and on subsequent signup requests while the feature is configured. Confirmed
  email, timestamp, consent version and source remain for consent records.
  Apply any deletion request to both the local record and Resend; unsubscribing
  alone is not deletion. Infrastructure/provider records have separate retention.
- A provider failure during activation leaves the confirmation retryable.
  A failed confirmation-email send retains the cooldown to limit repeat attempts.
  Provider error bodies and email addresses are not logged by this module.

To pause new signups, remove `NEWSLETTER_RESEND_API_KEY` and restart the API;
existing Resend subscriptions and unsubscribe preferences remain intact. Roll
back the API image if needed; leave the additive table in place to preserve
consent records. Restore the website signup CTA to Substack while unavailable.

## Validation

Run against a disposable PostgreSQL database (the suite truncates only its
newsletter table; other repository test helpers reset their entire test schema):

```sh
DATABASE_URL=postgres://USER:PASSWORD@localhost:PORT/TEST_DB npm test -- --runTestsByPath tests/newsletter.test.ts
npm run build
```

The newsletter suite uses real PostgreSQL transactions and mocks all Resend
network calls. It checks explicit consent, origin/honeypot controls, scanner
GETs, hashed tokens, topic-scoped writes, global opt-out, replay, expiry,
concurrency, retries, email cooldowns and pending-record cleanup.
