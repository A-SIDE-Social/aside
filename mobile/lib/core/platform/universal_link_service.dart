import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../config/env.dart';
import 'deep_link.dart';

/// Bridges incoming Universal Links (iOS) / App Links (Android) into
/// the in-app router via [pendingDeepLinkProvider].
///
/// We accept exactly one URL shape today:
/// `https://<configured-host>/<12-char slug>`. Anything else is
/// logged and dropped. The native AASA / App Links configuration
/// should be kept equally narrow.
///
/// Lifecycle: initialized once from AsideApp.initState. Handles both
/// the cold-start link (the URL that launched the app) and the
/// warm-resume stream (taps that arrive while the app is alive). The
/// service is fire-and-forget once initialized — no teardown needed
/// because the underlying [AppLinks] stream lives for the app's
/// lifetime.
class UniversalLinkService {
  UniversalLinkService({required this.onDeepLink});

  /// Called when a recognized slug URL produces an in-app route.
  /// Wired from AsideApp to push the route into [pendingDeepLinkProvider].
  final void Function(String route) onDeepLink;

  static const _slugPattern = r'^[a-z0-9]{12}$';

  final AppLinks _appLinks = AppLinks();

  // Kept as a field rather than fire-and-forget so a future dispose()
  // can cancel cleanly if we ever want to. The service lives for the
  // app's lifetime today, but a hot-reload race or a future
  // SignOutAllDevices flow might want a clean teardown.
  // ignore: unused_field
  StreamSubscription<Uri>? _sub;

  Future<void> initialize() async {
    // Cold-start: the URL that launched the app, if any. `app_links`
    // returns null if the app was launched normally (icon tap, push
    // notification, etc.). Must be polled BEFORE attaching the stream
    // so we don't miss the initial-link race window.
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        _routeForUri(initial);
      }
    } catch (e) {
      // app_links throws on platforms it doesn't support (e.g. unit
      // tests in pure-Dart). Swallow and continue — the stream below
      // will be empty in those environments too.
      debugPrint('[UniversalLink] initial link fetch failed: $e');
    }

    // Warm-resume: taps that arrive while the app is foregrounded or
    // backgrounded. iOS routes via NSUserActivity → AppDelegate;
    // Android via Intent → MainActivity. `app_links` plugs into both.
    _sub = _appLinks.uriLinkStream.listen(
      _routeForUri,
      onError: (e) {
        debugPrint('[UniversalLink] stream error: $e');
      },
    );
  }

  void _routeForUri(Uri uri) {
    debugPrint('[UniversalLink] received: $uri');
    // Reject anything that isn't a configured app-link host on a path
    // of exactly one slug-shaped segment. This is the defense if the
    // AASA / App-Link pattern is ever loosened (or a future build
    // accidentally registers a wider intent-filter).
    if (!_isOurHost(uri.host)) return;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 1) return;
    final slug = segments.single;
    if (!RegExp(_slugPattern).hasMatch(slug)) return;
    onDeepLink('/u/$slug');
  }

  bool _isOurHost(String host) => Env.appLinkHosts.contains(host.toLowerCase());
}
