# Home Screen widgets

On iOS 17 and later, each widget can select one mutual connection or one of the
account's personal Lists. An empty selection uses all connections. Older
supported iOS versions retain a single all-connections photo widget. All sizes
open the pictured post; the containing app rechecks access before displaying it.

## Data flow

The app writes configuration choices and an atomic account/widget-credential snapshot to
its existing App Group container. Source identifiers include the account ID.
The widget's configuration intent is not discoverable as a general shortcut.
A removed source or another account's selection produces an empty widget,
without falling back to another person's feed.

`GET /v1/feed/widget` returns one eligible image without comments or reactions.
It applies mutual-connection checks, the chosen List's ownership and current
membership, the post's snapshotted audience, deletion/expiry and the caller's
history allowance. It excludes the caller's own posts. Each request independently
checks authorization; push notifications only request a timeline refresh.
Deploy this endpoint before releasing the updated mobile app. It needs no schema
migration and does not change the regular feed.

The extension uses an ephemeral network session, does not attach credentials to
media downloads, caps image input at 10 MiB and downsamples to 600 pixels. It
checks the active session again after downloading. The app obtains a read-only credential from `POST /v1/widgets/session` using its
current access and refresh credentials. Widget credentials use a separate
signing key and are accepted only on the widget-photo endpoint. They expire
after 30 days and are checked against the current server login session on every
request, so revocation, sign-out and account deletion take effect on the next
widget request. Refresh tokens never enter the widget container. The operating system protects
these files until the first device unlock; this permits later background refresh.

It does not persist photos
or signed media URLs to the App Group cache. It requests a refresh after 30 minutes and supplies an empty timeline entry at
the earlier of 24 hours or the post/history expiry. WidgetKit may refresh later
than requested; this avoids making the widget blank at every routine refresh
budget delay. Expired widget credentials require opening the app to refresh.

Signing out removes the widget session, cached choices and legacy photo cache,
then requests a timeline reload. This cannot recall an image already captured
by the system or somebody viewing the device. WidgetKit controls refresh timing
and may retain a prior snapshot. Photos and names are marked privacy-sensitive;
users should choose content suitable for their Home Screen.

## Verification

- `swift test --package-path mobile/ios/WidgetShared`: account boundaries,
  endpoint selection, expiry and cache removal.
- `flutter test`: exact-post links, malformed/cross-account links, setup layout,
  authentication, invitations and existing app behavior.
- `tests/widgets.test.ts`: HTTP tests against a disposable local database whose
  name ends in `_tests`; checks access, sources, history, deletion and fallback
  from photo to video thumbnail. Never run it against a production database.
- Native build: compile the widget extension and app with Xcode, including
  App Intents metadata extraction.
- Device checks: configure separate friend/List widgets, change one without
  changing the other, open the pictured post from cold/warm app states, sign out,
  switch accounts, remove a connection/List, delete/expire a post, and retry with
  network unavailable. Check a previously installed widget after upgrading.
