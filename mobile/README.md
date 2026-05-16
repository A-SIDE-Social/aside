# A/SIDE Mobile

Flutter client for A/SIDE. The backend lives in `../src`; read the root
README first for setup and configuration.

## Development

Prerequisites: Flutter SDK 3.5+, Xcode 16+ for iOS builds, Android SDK,
CocoaPods, and Rust.

```sh
flutter pub get
flutter run
```

Useful checks:

```sh
flutter analyze
flutter test
cd rust && cargo test
```

## Build-Time Configuration

All public deployment constants are supplied with `--dart-define`:

```sh
flutter build apk --debug \
  --dart-define API_BASE_URL=http://localhost:3000 \
  --dart-define WS_BASE_URL=http://localhost:3000 \
  --dart-define APP_BASE_URL=http://localhost:3000 \
  --dart-define APP_LINK_HOSTS=localhost \
  --dart-define TERMS_URL=http://localhost:3000/terms \
  --dart-define PRIVACY_URL=http://localhost:3000/privacy \
  --dart-define SUPPORT_EMAIL=support@example.com \
  --dart-define APP_NAME=A/SIDE
```

Hosted A/SIDE production builds inject these values from the private
deploy repo. Self-hosters should do the same from their own build
pipeline.

## Firebase And Signing

- iOS needs a real `ios/Runner/GoogleService-Info.plist` for Firebase.
  The checked-in file is a placeholder.
- Android needs `android/app/google-services.json` for Firebase. The
  Google Services Gradle plugin is skipped when the file is absent.
- Android release signing uses `android/key.properties` when present;
  otherwise release configuration falls back to debug signing so local
  builds can configure without private keystores.

## Legacy Native IDs

The checked-in native projects still contain the hosted app's legacy
bundle/package IDs and app group/channel names. Self-hosted app-store
builds must update:

- iOS bundle IDs, app groups, app-link domains, and signing team.
- Android `namespace`, `applicationId`, package path, and app-link hosts.
- Firebase app registrations for those IDs.
- Store listings and associated domains.

This initial public release documents that work instead of broadly
renaming native project files.
