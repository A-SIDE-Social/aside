import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'deep_link.dart';

/// Keeps a link pending through sign-in and startup. Both cold and warm
/// delivery use this same path, so auth redirects cannot consume the invite.
class PendingDeepLinkListener extends ConsumerStatefulWidget {
  const PendingDeepLinkListener(
      {super.key,
      required this.router,
      required this.authenticated,
      required this.child});

  final GoRouter router;
  final bool authenticated;
  final Widget child;

  @override
  ConsumerState<PendingDeepLinkListener> createState() =>
      _PendingDeepLinkListenerState();
}

class _PendingDeepLinkListenerState
    extends ConsumerState<PendingDeepLinkListener> {
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingDeepLinkProvider);
    if (widget.authenticated && pending != null && !_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (!mounted || !widget.authenticated) return;
        final current = ref.read(pendingDeepLinkProvider);
        if (current == null) return;
        ref.read(pendingDeepLinkProvider.notifier).set(null);
        if (widget.router.state.uri.toString() != current) {
          widget.router.push(current);
        }
      });
    }
    return widget.child;
  }
}
