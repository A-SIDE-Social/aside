# A/SIDE

A private social app for the friends who actually know you.
Photos, videos, text posts, and end-to-end encrypted DMs. No ads,
no algorithmic feed, no analytics SDK, and no AI training on user
content.

The hosted version of A/SIDE lives at <https://a-side.social>. This
repository is the canonical open-source code for the backend and
Flutter client. Hosted A/SIDE production builds are made from this
repo plus private build-time configuration.

## What's In Here

```text
src/        Node + Express + Postgres backend
mobile/     Flutter client for iOS + Android, with Rust E2EE primitives
tests/      Backend integration and unit tests
docker-compose.yml + Dockerfile.dev    Local dev stack
```

## Architecture

- Mobile talks to the API over HTTPS plus Socket.IO for live updates.
- The API is a stateless TypeScript service backed by Postgres 17.
- DMs use Signal Protocol primitives through Signal's upstream
  `libsignal` Rust code, exposed to Dart through `flutter_rust_bridge`.
- Push notifications use Firebase Cloud Messaging.
- Subscriptions are optional and use RevenueCat when configured.
- Object storage is S3-compatible: AWS S3, DigitalOcean Spaces,
  Cloudflare R2, MinIO, and similar providers work.

## Running Locally

Prereqs: Docker + Docker Compose, Node 20+, Flutter SDK 3.5+, Rust
toolchain.

```sh
cp .env.example .env
docker compose up -d db
npm install
npm run migrate
npm run dev
```

The API runs on `http://localhost:3000`. Verify with:

```sh
curl http://localhost:3000/health
```

For the mobile app:

```sh
cd mobile
flutter pub get
flutter run
```

In development, set `DEV_OTP=123456` in `.env` if you want fixed
OTP sign-in without wiring Postmark. Use the seeded invite code
`testinvite0000`.

## Configuration

Backend runtime config is env-driven. Important public-facing values:

- `PUBLIC_APP_URL`: base URL for local/self-hosted web links.
- `INVITE_LINK_HOST`: base URL used when the server creates personal
  invite links.
- `INVITE_LINK_ALLOWED_HOSTS`: comma-separated hosts accepted when a
  user pastes an invite URL.
- `SUPPORT_EMAIL`, `LEGAL_TERMS_URL`, `LEGAL_PRIVACY_URL`: operator
  support and legal surfaces.
- `MARKETING_FROM_EMAIL`, `MARKETING_REPLY_TO_EMAIL`,
  `UNSUBSCRIBE_BASE_URL`: optional broadcast email config.
- `SYSTEM_USER_EMAIL`: sentinel user email for dev/system-managed rows.

Flutter build-time config is supplied with `--dart-define`:

```sh
flutter build apk --debug \
  --dart-define API_BASE_URL=http://localhost:3000 \
  --dart-define WS_BASE_URL=http://localhost:3000 \
  --dart-define APP_BASE_URL=http://localhost:3000 \
  --dart-define APP_LINK_HOSTS=localhost \
  --dart-define TERMS_URL=http://localhost:3000/terms \
  --dart-define PRIVACY_URL=http://localhost:3000/privacy \
  --dart-define SUPPORT_EMAIL=support@example.com \
  --dart-define SOURCE_CODE_URL=https://github.com/A-SIDE-Social/aside
```

## Hosted Product Model

Hosted A/SIDE uses annual subscriptions only. Free accounts can see the
most recent 30 days of feed and message history.

- Pro Individual: $20/year for one account.
- Pro Family: $60/year for the owner plus up to 5 family members.

Store pricing and sale availability are managed in App Store Connect and
Google Play. RevenueCat maps the active annual store products to A/SIDE's
`pro` entitlement.

## Firebase, RevenueCat, Email

The repo does not contain real Firebase, signing, or service-account
credentials.

- iOS: replace `mobile/ios/Runner/GoogleService-Info.plist` with your
  Firebase config before a real device/App Store build.
- Android: place `mobile/android/app/google-services.json` before a
  Firebase-enabled build. The Google Services Gradle plugin is skipped
  when that file is absent so local debug builds can still configure.
- Backend push: keep the Firebase service-account JSON outside the
  repo and point `FIREBASE_SERVICE_ACCOUNT_PATH` at it.
- RevenueCat: optional. Set server/mobile keys only if you want paid
  subscriptions.
- Postmark: set `POSTMARK_API_TOKEN` and `OTP_FROM_EMAIL` for real OTP
  delivery.
- Resend: optional broadcast email provider. Add your own templates in
  `src/marketing/templates/`.

## Hosted Build Overlay

A/SIDE's hosted backend and app builds should be reproducible from:

- a public repo commit or tag,
- a private deploy repo commit,
- CI secrets or a secrets manager.

The private deploy repo should check out this public repo at `ASIDE_REF`,
inject production-only files and constants, build, and deploy from that
ephemeral checkout. It should not carry private source patches on top of
this repo. See `docs/hosted-build-overlay.md`.

## Mobile Bundle IDs

The checked-in iOS and Android projects still contain the hosted app's
legacy bundle/package identifiers. Self-hosters who publish their own
apps must change bundle IDs, app groups, app-link domains, signing teams,
Firebase app IDs, and store metadata. This is intentionally documented
rather than broadly renamed in this initial public release.

## License

AGPL-3.0. See `LICENSE`.

If you modify this code and run it as a network service, the AGPL
requires you to offer the corresponding source for your modified
version to users who interact with that service. Read the license text
for the exact terms.

## Contributing And Security

- See `CONTRIBUTING.md` for project principles and contribution scope.
- See `SECURITY.md` for vulnerability reporting.
- See `CODE_OF_CONDUCT.md` for community norms.
