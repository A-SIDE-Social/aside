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
  --dart-define SOURCE_CODE_URL=https://github.com/A-SIDE-Social/aside \
  --dart-define APP_NAME=A/SIDE
```

Hosted A/SIDE production builds inject these values from the private
deploy repo. Self-hosters should do the same from their own build
pipeline.

`SOURCE_CODE_URL` is used by the Settings source-code link. Keep it
pointing at the public source for hosted builds, or your fork for
self-hosted builds.

## Voice Captions

Version 1.6.0 adds an optional voice caption to posts containing a photo.
Tap **Add voice caption** to request microphone access and record up to
one minute. Preview or remove it before sharing. Playback is tap-only;
captions follow the post’s audience and history limits.

Deploy the backend with migration `030_voice_captions.sql` before releasing
the mobile build. Uploads use authenticated `POST /v1/posts/voice-captions`
with an `audio/mp4` body (M4A, at most 2 MiB) and an integer
`X-Voice-Duration-Ms` header (1–60000). Pass the returned reservation ID as
`voice_caption_id` when creating the photo post. IDs belong to their uploader
and can only be attached once. Fetch audio through authenticated
`GET /v1/posts/{id}/voice-caption`; post responses contain duration metadata,
not public audio URLs.

Feed audio is server-stored, not end-to-end encrypted. It uses the existing
private object store in production and the ignored `private-uploads/`
directory locally. No transcription service is involved. Local drafts retain
recordings until shared or deleted. Post/account deletion queues stored audio
for cleanup; abandoned uploads are queued after 24 hours by the existing
media-deletion worker. Object removal follows the worker’s retry schedule.

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

Android App Links also require each production host to serve a Digital
Asset Links file at `/.well-known/assetlinks.json` with the app package
name and Play App Signing SHA-256 certificate fingerprint.

This initial public release documents that work instead of broadly
renaming native project files.
