import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/media/film_filters.dart';

/// Renders a child image with a [FilmFilter] applied — color matrix first,
/// then a tileable grain overlay composited with `softLight` blend mode.
///
/// Why a single widget:
/// - Three call sites previously wrapped images with raw `ColorFiltered`.
///   Grain adds a second composition step, so centralizing keeps them in
///   sync.
/// - The grain asset is loaded via `AssetImage`, which Flutter caches, so
///   multiple `FilteredImage` instances share the decoded texture.
///
/// Blend math:
/// - Grain is a grayscale PNG centered on mid-gray (128). `softLight`
///   lightens where pixels > 128 and darkens where < 128, magnitude
///   proportional to distance from mid. So mean-preserving noise adds
///   texture without shifting overall exposure.
/// - `filter.grain` (0–1) scales the opacity of the overlay via a layer
///   `saveLayer` — this is the only reliable way in Flutter to blend
///   a widget against what's *beneath* it (not against a color).
class FilteredImage extends StatelessWidget {
  final FilmFilter filter;
  final Widget child;

  /// Optional explicit size. If the child already has bounds, unnecessary.
  final double? width;
  final double? height;

  const FilteredImage({
    super.key,
    required this.filter,
    required this.child,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    Widget result = filter.isNone
        ? child
        : ColorFiltered(colorFilter: filter.toColorFilter(), child: child);

    if (filter.grain > 0) {
      result = Stack(
        fit: StackFit.passthrough,
        children: [
          result,
          Positioned.fill(
            child: IgnorePointer(
              child: _BlendMask(
                blendMode: BlendMode.softLight,
                opacity: filter.grain,
                child: Image.asset(
                  'assets/grain.png',
                  fit: BoxFit.cover,
                  repeat: ImageRepeat.repeat,
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (width != null || height != null) {
      result = SizedBox(width: width, height: height, child: result);
    }
    return result;
  }
}

/// Blends the child's paint with whatever has been painted *beneath* it
/// using the given [blendMode] and [opacity].
///
/// Flutter's built-in `ColorFiltered` only blends a widget with a solid
/// color, not with the stack below. To blend against the background we
/// wrap the subtree in a `saveLayer` whose `Paint.blendMode` controls
/// how it composites down.
class _BlendMask extends SingleChildRenderObjectWidget {
  final BlendMode blendMode;
  final double opacity;

  const _BlendMask({
    required this.blendMode,
    required this.opacity,
    required Widget super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBlendMask(blendMode, opacity);

  @override
  void updateRenderObject(BuildContext context, _RenderBlendMask r) {
    r.blendMode = blendMode;
    r.opacity = opacity;
  }
}

class _RenderBlendMask extends RenderProxyBox {
  BlendMode _blendMode;
  double _opacity;

  _RenderBlendMask(this._blendMode, this._opacity);

  set blendMode(BlendMode value) {
    if (_blendMode == value) return;
    _blendMode = value;
    markNeedsPaint();
  }

  set opacity(double value) {
    if (_opacity == value) return;
    _opacity = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.canvas.saveLayer(
      offset & size,
      Paint()
        ..blendMode = _blendMode
        ..color = Color.fromRGBO(255, 255, 255, _opacity),
    );
    super.paint(context, offset);
    context.canvas.restore();
  }
}
