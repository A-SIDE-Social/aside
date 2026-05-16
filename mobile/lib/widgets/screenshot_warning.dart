// Slide-up privacy banner shown when the user takes a screenshot
// while in A/SIDE.
//
// Anchored at the top of the screen via an OverlayEntry. Slides in
// over 250ms, holds 4s, slides out. Tappable to dismiss early.
// We can't block screenshots — this is gentle awareness, not
// enforcement.
//
// The mounting lifecycle (insert / replace / cancel) is owned by
// _AsideAppState in app.dart so we can guarantee:
//  - one banner at a time (re-firing replaces, doesn't stack)
//  - timer cancels on app pause + on dispose
//  - graceful no-op if no Overlay context exists yet (e.g. auth
//    splash, pre-router-mount frames)
//
// This file just provides the widget itself; mounting happens via
// the helpers exported below.

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/config/app_colors.dart';

/// Public copy used in the banner. Exposed so unit tests can pin it
/// without a golden file.
///
/// Stronger language than the gentle v1 copy ("Please be thoughtful")
/// because the soft framing wasn't reading as policy. Screenshots
/// of others' content are a community-policy violation; the banner
/// now states that explicitly so the reader understands the
/// consequence (suspension), not just the social cost.
const String kScreenshotWarningTitle = 'Screenshots are not allowed on A/SIDE.';
const String kScreenshotWarningBody =
    'Sharing other people’s content off the platform may lead to account suspension.';

class ScreenshotWarning extends StatefulWidget {
  /// Called when the user taps the banner to dismiss early.
  final VoidCallback onDismiss;

  const ScreenshotWarning({super.key, required this.onDismiss});

  @override
  State<ScreenshotWarning> createState() => _ScreenshotWarningState();
}

class _ScreenshotWarningState extends State<ScreenshotWarning>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1.5),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: SlideTransition(
          position: _slide,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Material(
              color: colors.surfaceAlt,
              elevation: 6,
              borderRadius: BorderRadius.circular(14),
              shadowColor: Colors.black26,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: widget.onDismiss,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.camera_alt_outlined,
                        size: 20,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              kScreenshotWarningTitle,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              kScreenshotWarningBody,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.textSecondary,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lightweight controller pattern used by [showScreenshotWarning].
/// Holds the OverlayEntry + auto-dismiss timer so the caller can
/// cancel/replace cleanly.
class ScreenshotWarningHandle {
  final OverlayEntry entry;
  final Timer dismissTimer;
  ScreenshotWarningHandle(this.entry, this.dismissTimer);

  void cancel() {
    dismissTimer.cancel();
    if (entry.mounted) entry.remove();
  }
}

/// Mount the banner into [overlay]. Returns a handle the caller
/// MUST hold and call [ScreenshotWarningHandle.cancel] on when
/// replacing or tearing down (e.g. another screenshot fires while
/// this one is still visible, or app backgrounds, or the listener
/// is disposed). Without that, the OverlayEntry stays mounted past
/// its useful life.
ScreenshotWarningHandle showScreenshotWarning(OverlayState overlay) {
  late final ScreenshotWarningHandle handle;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => ScreenshotWarning(
      onDismiss: () => handle.cancel(),
    ),
  );
  final timer = Timer(const Duration(seconds: 4), () {
    if (entry.mounted) entry.remove();
  });
  handle = ScreenshotWarningHandle(entry, timer);
  overlay.insert(entry);
  return handle;
}
