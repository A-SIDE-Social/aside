import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_view/photo_view.dart';

import '../../core/media/film_filters.dart';
import '../../core/media/media_transform.dart';
import '../../widgets/widgets.dart';

/// Opens a full-sheet media editor for picking filters and applying
/// simple straighten+crop (pinch-zoom, pan, ±15° rotation) on each
/// image in [photos]. Writes changes back through [onFilterChanged]
/// and [onTransformChanged] as they happen — the caller stores the
/// authoritative maps by media index.
///
/// Why a dedicated StatefulWidget rather than showModalBottomSheet +
/// StatefulBuilder: the older approach had four levels of state
/// (parent state, outer builder closure, StatefulBuilder, PageView
/// controller) drifting out of sync during async image-aspect loads
/// and parent rebuilds. One widget = one state = deterministic.
Future<void> showMediaEditSheet(
  BuildContext context, {
  required List<XFile> photos,
  required List<int> photoMediaIndices,
  required int initialIndex,
  required FilmFilter Function(int mediaIdx) filterFor,
  required MediaTransform Function(int mediaIdx) transformFor,
  required void Function(int mediaIdx, FilmFilter) onFilterChanged,
  required void Function(int mediaIdx, MediaTransform) onTransformChanged,
}) async {
  final initialPage = photoMediaIndices.indexOf(initialIndex);
  if (initialPage < 0) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.black,
    enableDrag: true,
    builder: (ctx) => _MediaEditSheet(
      photos: photos,
      photoMediaIndices: photoMediaIndices,
      initialPage: initialPage,
      filterFor: filterFor,
      transformFor: transformFor,
      onFilterChanged: onFilterChanged,
      onTransformChanged: onTransformChanged,
    ),
  );
}

class _MediaEditSheet extends StatefulWidget {
  final List<XFile> photos;

  /// Maps page-index (0..photos.length-1) to the parent's media index
  /// (into its full `_selectedMedia` list). Let the parent carry the
  /// shape "photos + videos" while we only iterate the photo subset.
  final List<int> photoMediaIndices;
  final int initialPage;
  final FilmFilter Function(int mediaIdx) filterFor;
  final MediaTransform Function(int mediaIdx) transformFor;
  final void Function(int mediaIdx, FilmFilter) onFilterChanged;
  final void Function(int mediaIdx, MediaTransform) onTransformChanged;

  const _MediaEditSheet({
    required this.photos,
    required this.photoMediaIndices,
    required this.initialPage,
    required this.filterFor,
    required this.transformFor,
    required this.onFilterChanged,
    required this.onTransformChanged,
  });

  @override
  State<_MediaEditSheet> createState() => _MediaEditSheetState();
}

class _MediaEditSheetState extends State<_MediaEditSheet> {
  late final PageController _pageController;
  late int _currentPage;

  /// Cached image aspects (width / height), keyed by PAGE INDEX.
  final Map<int, double> _aspects = {};

  /// Sheet-owned filter map, seeded from the parent at open time.
  /// Every mutation updates this map and calls `setState` — the parent
  /// is notified via `widget.onFilterChanged` for durable persistence,
  /// but the parent's setState does NOT rebuild this modal (different
  /// Navigator route), so the authoritative UI state lives here.
  final Map<int, FilmFilter> _filters = {};

  /// Sheet-owned transform map, same pattern as `_filters`.
  final Map<int, MediaTransform> _transforms = {};

  /// One PhotoViewController per page, keyed by media index. Owns the
  /// scale/position state for the duration of the sheet. Created on
  /// open, disposed on close. The stream listener (in `_controllerSubs`)
  /// syncs every change back into `_transforms` so the export pipeline
  /// always sees the current edit.
  final Map<int, PhotoViewController> _controllers = {};
  final Map<int, StreamSubscription<PhotoViewControllerValue>> _controllerSubs =
      {};

  /// PageView swipe gate. True while any gesture is mid-update or the
  /// current scale is zoomed past 1.0×.
  bool _swipeBlocked = false;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _pageController = PageController(initialPage: widget.initialPage);
    _seedFromParent();
    _setupControllers();
    _preloadAspects();
  }

  /// Copy the parent's current filter/transform state into our local
  /// maps. Called once at open — after this, the sheet is authoritative
  /// until it dismisses.
  ///
  /// Only rotation is preserved across sheet sessions. Scale/offset live
  /// inside the PhotoViewController for the sheet's lifetime; restoring
  /// them across opens would require post-frame controller seeding that
  /// fights photo_view's `contained` scale semantics. The product cost
  /// is small: re-opening the editor resets zoom/pan but keeps the
  /// straighten angle, and the filter, intact.
  void _seedFromParent() {
    for (var i = 0; i < widget.photoMediaIndices.length; i++) {
      final mediaIdx = widget.photoMediaIndices[i];
      final f = widget.filterFor(mediaIdx);
      if (!f.isNone) _filters[mediaIdx] = f;
      final t = widget.transformFor(mediaIdx);
      if (t.rotation != 0.0) {
        _transforms[mediaIdx] = MediaTransform(rotation: t.rotation);
      }
    }
  }

  /// Builds one [PhotoViewController] per page and subscribes to its
  /// state stream. Every controller-driven change (pinch, pan, double-
  /// tap zoom) flows through `_onControllerUpdate` into `_transforms`
  /// so the export pipeline matches what the user sees.
  void _setupControllers() {
    for (var page = 0; page < widget.photos.length; page++) {
      final mediaIdx = widget.photoMediaIndices[page];
      final controller = PhotoViewController();
      _controllers[mediaIdx] = controller;
      _controllerSubs[mediaIdx] = controller.outputStateStream.listen(
        (state) => _onControllerUpdate(mediaIdx, state),
      );
    }
  }

  /// Called whenever a [PhotoViewController] emits — typically on every
  /// pinch/pan tick. Writes the new scale/offset into `_transforms` and
  /// notifies the parent for durable persistence. Does NOT call
  /// `setState`: photo_view rebuilds its own subtree off the controller,
  /// and the rotation slider doesn't depend on scale/offset, so a sheet-
  /// wide rebuild here would be wasteful.
  void _onControllerUpdate(int mediaIdx, PhotoViewControllerValue state) {
    // photo_view emits an initial null-scale value during layout while
    // it computes the "contained" baseline; treat that as no change.
    final current = _transforms[mediaIdx] ?? MediaTransform.identity;
    final nextScale = state.scale ?? current.scale;
    if (nextScale == current.scale && state.position == current.offset) {
      return;
    }
    final updated = current.copyWith(
      scale: nextScale,
      offset: state.position,
    );
    if (updated.isIdentity) {
      _transforms.remove(mediaIdx);
    } else {
      _transforms[mediaIdx] = updated;
    }
    widget.onTransformChanged(mediaIdx, updated);
  }

  FilmFilter _filterFor(int mediaIdx) => _filters[mediaIdx] ?? FilmFilters.none;

  MediaTransform _transformForMedia(int mediaIdx) =>
      _transforms[mediaIdx] ?? MediaTransform.identity;

  @override
  void dispose() {
    for (final sub in _controllerSubs.values) {
      sub.cancel();
    }
    _controllerSubs.clear();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    _pageController.dispose();
    super.dispose();
  }

  /// Decode just enough of each image to learn its width/height, cache
  /// the aspect, rebuild the sheet when each lands. Running all of
  /// them in parallel keeps the first-page-visible latency short.
  Future<void> _preloadAspects() async {
    for (var page = 0; page < widget.photos.length; page++) {
      _loadOneAspect(page);
    }
  }

  Future<void> _loadOneAspect(int page) async {
    try {
      final bytes = await File(widget.photos[page].path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      if (!mounted || h == 0) return;
      setState(() {
        _aspects[page] = w / h;
      });
    } catch (_) {
      // Fall back to the 1.0 default. Preview stays usable; the worst
      // case is a single photo showing square for one frame.
    }
  }

  int get _currentMediaIdx => widget.photoMediaIndices[_currentPage];

  double _aspectForPage(int page) => _aspects[page] ?? 1.0;

  void _onPageChanged(int page) {
    setState(() => _currentPage = page);
  }

  /// Write a transform into local state AND notify the parent. Every
  /// transform mutation path funnels through here. Always calls
  /// `setState` — the sheet rebuilds even if the swipe-block flag
  /// didn't change, so the `_EditablePage` sees the new `transform`
  /// prop and adopts it (fixes "reset only works after tapping a
  /// filter," which was the smoking gun of modal state isolation).
  void _handleTransformChanged(MediaTransform t) {
    final mediaIdx = _currentMediaIdx;
    setState(() {
      if (t.isIdentity) {
        _transforms.remove(mediaIdx);
      } else {
        _transforms[mediaIdx] = t;
      }
      _swipeBlocked = t.scale > 1.0;
    });
    widget.onTransformChanged(mediaIdx, t);
  }

  /// Called while a gesture is active (pinch or pan), independent of
  /// whether the transform has changed meaningfully. Blocks PageView
  /// swipe the instant two fingers land. Always calls setState so the
  /// flag update reaches the PageView physics this frame.
  void _handleActiveGesture(bool active) {
    if (active == _swipeBlocked) return;
    setState(() => _swipeBlocked = active);
  }

  /// Apply the current straighten slider value to the current page.
  /// Auto-zooms the image if rotation requires it so no blank corners
  /// ever show. Reads scale from the controller (the source of truth for
  /// pinch state) so a manually-zoomed photo doesn't get clobbered when
  /// the user nudges the straighten slider.
  void _applyRotation(double rotation) {
    final mediaIdx = _currentMediaIdx;
    final current = _transformForMedia(mediaIdx);
    final aspect = _aspectForPage(_currentPage);
    final minScale = MediaTransform.minScaleForRotation(rotation, aspect);
    final controller = _controllers[mediaIdx];
    final currentScale = controller?.scale ?? current.scale;
    final newScale = math.max(currentScale, minScale);
    if (controller != null && newScale != currentScale) {
      // Pushing scale into the controller fires the state stream, which
      // updates `_transforms` via `_onControllerUpdate`. We still call
      // `_handleTransformChanged` below for the rotation update — it's
      // idempotent with the stream's scale write.
      controller.scale = newScale;
    }
    _handleTransformChanged(
      current.copyWith(rotation: rotation, scale: newScale),
    );
  }

  /// Write a filter into local state AND notify the parent. Same
  /// pattern as `_handleTransformChanged` — sheet is authoritative.
  void _handleFilterChanged(FilmFilter f) {
    final mediaIdx = _currentMediaIdx;
    setState(() {
      if (f.isNone) {
        _filters.remove(mediaIdx);
      } else {
        _filters[mediaIdx] = f;
      }
    });
    widget.onFilterChanged(mediaIdx, f);
  }

  void _resetCurrent() {
    final mediaIdx = _currentMediaIdx;
    // Reset the PhotoView controller first so the preview returns to
    // the contained baseline this frame. The stream listener will then
    // sync identity scale/offset back into `_transforms`; we still call
    // `_handleTransformChanged` to clear rotation and trigger setState.
    _controllers[mediaIdx]?.reset();
    _handleTransformChanged(MediaTransform.identity);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQueryHeight = MediaQuery.of(context).size.height;
    final activeMediaIdx = _currentMediaIdx;
    final activeTransform = _transformForMedia(activeMediaIdx);
    final activeFilter = _filterFor(activeMediaIdx);

    return SafeArea(
      child: SizedBox(
        height: mediaQueryHeight * 0.9,
        child: Column(
          children: [
            // Drag handle
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white38,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            // Page counter — reflects the authoritative _currentPage.
            if (widget.photos.length > 1)
              Text(
                '${_currentPage + 1} / ${widget.photos.length}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                physics:
                    _swipeBlocked ? const NeverScrollableScrollPhysics() : null,
                itemCount: widget.photos.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (_, page) {
                  final mediaIdx = widget.photoMediaIndices[page];
                  // Key by media index so PhotoView's internal state
                  // stays paired with the right controller across
                  // PageView recycles. The controller itself is owned
                  // by the sheet (in `_controllers`), not the page.
                  return _EditablePage(
                    key: ValueKey('edit-page-$mediaIdx'),
                    file: widget.photos[page],
                    filter: _filterFor(mediaIdx),
                    transform: _transformForMedia(mediaIdx),
                    aspect: _aspectForPage(page),
                    controller: _controllers[mediaIdx]!,
                    onActiveGesture: (active) {
                      if (page == _currentPage) {
                        _handleActiveGesture(active);
                      }
                    },
                  );
                },
              ),
            ),
            // Straighten slider + reset button. Reset is always
            // available when transform is dirty (not identity), so the
            // user can recover even if they've forgotten what they
            // changed.
            _StraightenBar(
              transform: activeTransform,
              onChanged: _applyRotation,
              onReset: activeTransform.isIdentity ? null : _resetCurrent,
            ),
            // Filter strip — writes through _handleFilterChanged which
            // updates local state + notifies parent.
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
              child: FilterPicker(
                imagePath: widget.photos[_currentPage].path,
                selectedFilter: activeFilter,
                // Pass the active transform so each thumbnail's
                // rotation matches what the user sees in the main
                // preview — picking a filter on a straightened photo
                // no longer shows misleadingly non-straightened
                // thumbnails. Scale/offset are applied only in the
                // preview (their units don't translate to thumbnails).
                transform: activeTransform,
                onFilterChanged: _handleFilterChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Single-page editor ──────────────────────────────────────────────

/// Renders one photo with pinch/pan/rotate support. Pinch-zoom and pan
/// are delegated to the `photo_view` package, which handles the gesture
/// arena with the parent PageView correctly (the previous custom
/// GestureDetector-based implementation was the source of the swipe/
/// zoom/pan conflicts). Rotation stays in our state, applied as a
/// Transform wrapping the image inside PhotoView's `customChild`.
///
/// The [controller] is owned by the sheet, one per media index,
/// persisted across PageView recycles. The sheet reads it to compute
/// the auto-zoom-on-rotation scale and to clear on reset.
class _EditablePage extends StatelessWidget {
  final XFile file;
  final FilmFilter filter;
  final MediaTransform transform;
  final double aspect;
  final PhotoViewController controller;

  /// Notifies when the user's interaction with PhotoView starts/ends —
  /// keeps the sheet's swipe-block flag in sync (blocks PageView swipes
  /// while user is actively zooming). photo_view handles gesture arena
  /// internally, but this hint lets the sheet show UI feedback.
  final ValueChanged<bool> onActiveGesture;

  const _EditablePage({
    super.key,
    required this.file,
    required this.filter,
    required this.transform,
    required this.aspect,
    required this.controller,
    required this.onActiveGesture,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRect(
          child: PhotoView.customChild(
            controller: controller,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.contained * 3.0,
            initialScale: PhotoViewComputedScale.contained,
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            // Rotation is applied INSIDE PhotoView's scale+pan, so
            // zooming in on a rotated image stays aligned to its
            // original center. The Transform uses the image's natural
            // size (via the inner Image.file), and photo_view wraps it
            // with its own scale/pan matrix on top.
            child: Transform.rotate(
              angle: transform.rotation,
              child: FilteredImage(
                filter: filter,
                child: Image.file(
                  File(file.path),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            scaleStateChangedCallback: (state) {
              // photo_view fires this when the user pinches past the
              // initial scale. We use it to toggle the sheet's swipe
              // block — zoomed = no PageView swipe, so single-finger
              // pan works without fighting the carousel.
              final isZoomed = state != PhotoViewScaleState.initial &&
                  state != PhotoViewScaleState.covering;
              onActiveGesture(isZoomed);
            },
          ),
        ),
      ),
    );
  }
}

// ─── Straighten slider ──────────────────────────────────────────────

class _StraightenBar extends StatelessWidget {
  final MediaTransform transform;
  final ValueChanged<double> onChanged;

  /// Null hides the reset chip — used to keep it invisible at identity.
  final VoidCallback? onReset;

  const _StraightenBar({
    required this.transform,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    // Snap to 0 near the center so "perfectly level" is easy to hit.
    const deadZone = 0.00873; // ~0.5°
    final rot = transform.rotation.abs() < deadZone ? 0.0 : transform.rotation;
    final degrees = (rot * 180 / math.pi).toStringAsFixed(1);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              '${rot >= 0 ? '+' : ''}$degrees°',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: Colors.white.withValues(alpha: 0.8),
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white10,
              ),
              child: Slider(
                value: rot,
                min: -MediaTransform.maxRotation,
                max: MediaTransform.maxRotation,
                onChanged: (v) => onChanged(v.abs() < deadZone ? 0.0 : v),
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: onReset == null
                ? const SizedBox.shrink()
                : TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(44, 32),
                    ),
                    onPressed: onReset,
                    child: const Text(
                      'Reset',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
