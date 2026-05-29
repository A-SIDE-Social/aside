# Hosted Build Overlay

This repo is the canonical source for backend and mobile code. Hosted
A/SIDE production builds should pull from this public repo at a pinned
commit or tag, then inject private configuration from a separate private
deploy repo.

## Private Repo Contents

Keep these outside the public repo:

- Production backend env files or secrets-manager references.
- `GoogleService-Info.plist` and `google-services.json`.
- Apple team ID, provisioning profile references, and signing setup.
- Android signing config and keystore references.
- Native associated-domain/App-Link host overrides for
  `mobile/ios/Runner/Runner.entitlements` and
  `mobile/android/app/src/main/AndroidManifest.xml`.
- Production `--dart-define` values for API URLs, app-link hosts,
  legal URLs, support email, and app name.
- Deployment CI/CD definitions.

## Backend Build Contract

The private deploy repo should:

1. Check out this repo at `ASIDE_REF`.
2. Build the backend Docker image from that checkout.
3. Run migrations from the same checkout.
4. Deploy with production env supplied by CI/secrets manager.

Do not keep private backend source patches in the deploy repo. If hosted
A/SIDE needs a code change, land it here first.

## Mobile Build Contract

The private deploy repo should:

1. Check out this repo at `ASIDE_REF`.
2. Copy Firebase config files into the ephemeral checkout.
3. Inject native associated-domain/App-Link hosts for the hosted domain.
4. Supply signing material through CI/keychain/Gradle properties.
5. Run `flutter build` with production `--dart-define` values.

Example defines:

```sh
--dart-define API_BASE_URL=https://api.example.com
--dart-define WS_BASE_URL=https://api.example.com
--dart-define APP_BASE_URL=https://example.com
--dart-define APP_LINK_HOSTS=example.com,www.example.com
--dart-define TERMS_URL=https://example.com/terms
--dart-define PRIVACY_URL=https://example.com/privacy
--dart-define SUPPORT_EMAIL=support@example.com
--dart-define SOURCE_CODE_URL=https://github.com/A-SIDE-Social/aside
--dart-define APP_NAME=A/SIDE
```

Use a disposable checkout for builds so injected private files never
become tracked changes in a developer's public working tree.

For Android App Links, the hosted web origin must also serve
`/.well-known/assetlinks.json` with the Android application ID and the
Play App Signing SHA-256 certificate fingerprint. The native manifest
hosts, `APP_LINK_HOSTS`, and the web-hosted Asset Links file must all
describe the same production domains.
