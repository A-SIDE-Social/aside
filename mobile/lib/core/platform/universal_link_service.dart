import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'invite_input.dart';

/// Routes OS-delivered links through the same parser as manual entry.
class UniversalLinkService {
  UniversalLinkService({required this.onDeepLink, AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  final void Function(String route) onDeepLink;
  final AppLinks _appLinks;
  StreamSubscription<Uri>? _sub;
  bool _disposed = false;

  Future<void> initialize() async {
    // Subscribe first so a new tap cannot disappear while the initial-link
    // query is in flight. A newer stream event takes precedence over that
    // initial value. The router also deduplicates repeated delivery.
    var receivedStreamLink = false;
    _sub = _appLinks.uriLinkStream.listen((uri) {
      receivedStreamLink = true;
      _routeForUri(uri);
    }, onError: (Object error) {
      debugPrint('[UniversalLink] stream unavailable');
    });
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null && !receivedStreamLink) _routeForUri(initial);
    } catch (_) {
      debugPrint('[UniversalLink] initial link unavailable');
    }
  }

  void _routeForUri(Uri uri) {
    if (_disposed) return;
    final invite = InviteInput.parse(uri.toString());
    if (invite != null) onDeepLink(invite.route);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
  }
}
