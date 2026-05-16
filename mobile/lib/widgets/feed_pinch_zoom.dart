import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Instagram-style pinch-to-zoom overlay for feed photos.
///
/// Wraps any visual child. When the user places two fingers on the
/// child, we insert an [OverlayEntry] that renders the child above the
/// rest of the UI, transformed to track the pinch (scale around the
/// pinch focal point + translation for finger movement). On release,
/// the transform snap-animates back to identity and the overlay is
/// torn down. While active, the in-place child is hidden (opacity 0)
/// so the feed layout doesn't reflow.
///
/// Design choices:
///
/// 1. **Pointer listener, not GestureDetector.** We use a bare
///    [Listener] so we never claim the gesture arena. Single-finger
///    drags pass straight through to the parent ListView (vertical
///    scroll) or PageView (carousel swipe). We only start zoom logic
///    on the 1→2 pointer transition, which parent scroll/drag
///    recognizers don't compete for.
///
/// 2. **Child is rendered in two places during a pinch.** The original
///    widget stays in the tree at opacity 0 (preserves layout) while
///    the overlay renders a second copy transformed. For
///    `CachedNetworkImage` children this is cheap — same URL = same
///    cached bitmap via Flutter's image cache. Do NOT wrap stateful
///    or resource-owning children (video players, etc.).
///
/// 3. **Snap-back is a short `Curves.easeOutCubic`.** 220ms matches
///    Instagram closely; longer feels laggy, shorter looks abrupt.
///
/// 4. **Overlay is positioned in global coords** using the anchor's
///    screen rect at pinch-start, then transformed. Any parent
///    scroll/reflow during the pinch is ignored — we render where we
///    started. Acceptable because a pinch is typically <1s and the
///    user isn't scrolling with two fingers down.
class FeedPinchZoom extends StatefulWidget {
  final Widget child;

  /// Optional rounded-corner clip applied to the overlay copy. Lets
  /// callers preserve the feed's corner radius as the image grows.
  final BorderRadius? borderRadius;

  /// Max scale factor. 4× is plenty for peek-at-detail; beyond feels
  /// like a different interaction (enter-detail-view).
  final double maxScale;

  const FeedPinchZoom({
    super.key,
    required this.child,
    this.borderRadius,
    this.maxScale = 4.0,
  });

  @override
  State<FeedPinchZoom> createState() => _FeedPinchZoomState();
}

class _FeedPinchZoomState extends State<FeedPinchZoom>
    with SingleTickerProviderStateMixin {
  final GlobalKey _anchorKey = GlobalKey();

  /// Active pointers and their latest positions (global coords).
  final Map<int, Offset> _pointers = {};

  OverlayEntry? _overlay;

  // State captured at pinch-start.
  Rect _anchorRect = Rect.zero;
  double _initialDistance = 1;
  Offset _initialFocal = Offset.zero;

  // Live transform values — read by the overlay builder.
  double _scale = 1.0;
  Offset _focalDelta = Offset.zero;

  // Snap-back animation.
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  double _snapFromScale = 1.0;
  Offset _snapFromFocal = Offset.zero;

  bool get _active => _overlay != null;

  @override
  void initState() {
    super.initState();
    _snap
      ..addListener(() {
        final t = Curves.easeOutCubic.transform(_snap.value);
        _scale = lerpDouble(_snapFromScale, 1.0, t)!;
        _focalDelta = Offset.lerp(_snapFromFocal, Offset.zero, t)!;
        _overlay?.markNeedsBuild();
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _tearDown();
      });
  }

  @override
  void dispose() {
    _overlay?.remove();
    _overlay = null;
    _snap.dispose();
    super.dispose();
  }

  // ─── Pointer tracking ────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2 && !_active && !_snap.isAnimating) {
      _startPinch();
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_active && _pointers.length >= 2) _updatePinch();
  }

  void _onPointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_active && _pointers.length < 2 && !_snap.isAnimating) {
      _endPinch();
    }
  }

  // ─── Pinch lifecycle ─────────────────────────────────────────────

  void _startPinch() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;

    _anchorRect = box.localToGlobal(Offset.zero) & box.size;

    final points = _pointers.values.toList();
    _initialDistance = (points[0] - points[1]).distance;
    if (_initialDistance == 0) _initialDistance = 1; // guard div-by-0
    _initialFocal = Offset(
      (points[0].dx + points[1].dx) / 2,
      (points[0].dy + points[1].dy) / 2,
    );
    _scale = 1.0;
    _focalDelta = Offset.zero;

    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
    setState(() {}); // trigger the opacity-0 on the original
  }

  void _updatePinch() {
    final points = _pointers.values.toList();
    final currentDistance = (points[0] - points[1]).distance;
    final currentFocal = Offset(
      (points[0].dx + points[1].dx) / 2,
      (points[0].dy + points[1].dy) / 2,
    );
    _scale = (currentDistance / _initialDistance).clamp(1.0, widget.maxScale);
    _focalDelta = currentFocal - _initialFocal;
    _overlay!.markNeedsBuild();
  }

  void _endPinch() {
    _snapFromScale = _scale;
    _snapFromFocal = _focalDelta;
    _snap.forward(from: 0);
  }

  void _tearDown() {
    _overlay?.remove();
    _overlay = null;
    if (mounted) setState(() {});
  }

  // ─── Overlay content ─────────────────────────────────────────────

  Widget _buildOverlay(BuildContext context) {
    // Focal point relative to the anchor's top-left. We scale around
    // this point so the pixel under the user's pinch center stays
    // under it throughout the gesture.
    final rf = _initialFocal - _anchorRect.topLeft;

    // Compose: translate by focal delta (finger movement while pinched),
    // then scale around the relative focal. Matrix4 applies bottom-up,
    // so the order below reads "innermost-first": translate(rf),
    // scale, translate(-rf), then translate(delta).
    final matrix = Matrix4.identity()
      ..translateByDouble(_focalDelta.dx, _focalDelta.dy, 0, 1)
      ..translateByDouble(rf.dx, rf.dy, 0, 1)
      ..scaleByDouble(_scale, _scale, 1, 1)
      ..translateByDouble(-rf.dx, -rf.dy, 0, 1);

    Widget content = widget.child;
    if (widget.borderRadius != null) {
      content = ClipRRect(borderRadius: widget.borderRadius!, child: content);
    }

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            Positioned(
              left: _anchorRect.left,
              top: _anchorRect.top,
              width: _anchorRect.width,
              height: _anchorRect.height,
              child: Transform(transform: matrix, child: content),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Why RawGestureDetector here:
    //
    // The Listener below tracks pointer events but does NOT claim the
    // gesture arena. Without another arena participant, the parent
    // ListView's drag recognizer keeps scrolling the feed during a
    // 2-finger pinch — vertical components of the pinch bleed through
    // as scroll, and the feed shifts under the overlay. On release
    // the overlay snap-backs to the original anchor rect, which has
    // now moved, producing a jump.
    //
    // The custom _TwoFingerClaimRecognizer stays neutral for single
    // pointers (so 1-finger drags still reach the ListView and the
    // feed scrolls normally) and only wins the arena when a 2nd
    // pointer lands on the widget. The arena win cancels the parent
    // ListView's active drag, freezing the feed for the duration of
    // the pinch.
    //
    // The Listener still fires for every pointer event — it's a
    // RenderPointerListener, not an arena participant — so the pinch
    // math continues to work unchanged.
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        _TwoFingerClaimRecognizer:
            GestureRecognizerFactoryWithHandlers<_TwoFingerClaimRecognizer>(
          () => _TwoFingerClaimRecognizer(debugOwner: this),
          (_) {},
        ),
      },
      behavior: HitTestBehavior.translucent,
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerUp,
        child: SizedBox(
          key: _anchorKey,
          child: Opacity(
            opacity: _active ? 0 : 1,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Arena participant that stays neutral for single pointers and wins
/// (resolves `accepted`) as soon as a 2nd pointer lands on the widget.
/// Used by [FeedPinchZoom] to freeze the parent ListView during a
/// 2-finger pinch without interfering with single-finger drags.
class _TwoFingerClaimRecognizer extends OneSequenceGestureRecognizer {
  _TwoFingerClaimRecognizer({super.debugOwner});

  final Set<int> _pointers = <int>{};
  bool _claimed = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer);
    _pointers.add(event.pointer);
    if (_pointers.length >= 2 && !_claimed) {
      _claimed = true;
      // Winning the arena cancels any competing recognizers on this
      // pointer sequence — in practice, the parent ListView's
      // VerticalDragGestureRecognizer, which then stops scrolling.
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointers.remove(event.pointer);
      stopTrackingPointer(event.pointer);
      if (_pointers.isEmpty) {
        _claimed = false;
      }
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    // Arena resolution is driven by `addAllowedPointer` when a 2nd
    // pointer lands; single-pointer sequences simply fall off without
    // claiming anything, which is what we want.
  }

  @override
  void rejectGesture(int pointer) {
    _pointers.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  String get debugDescription => 'FeedPinchZoom two-finger claim';
}
