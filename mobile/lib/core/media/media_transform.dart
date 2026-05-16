import 'dart:math' as math;
import 'dart:ui';

/// User-applied transform (crop + straighten) on a single image, on top
/// of any [FilmFilter] selection. Applied before the filter color matrix
/// in the export pipeline so straighten rotates the source pixels, then
/// the filter colors the rotated result — not vice versa.
///
/// Crop is expressed as a post-rotation zoom + pan within the original
/// aspect ratio. There is no user-selectable aspect ratio in v1; the
/// output dimensions always match the input.
class MediaTransform {
  /// Clockwise rotation in radians. Clamped to `±π/12` (±15°) in the
  /// constructor — straightening, not rotating. Values outside that
  /// range are clamped silently rather than rejected, because the
  /// slider UI can briefly land outside during drag.
  final double rotation;

  /// Uniform scale factor. Clamped to `[1.0, 3.0]` — you can zoom in
  /// to reframe, never out (zooming out would leave empty pixels where
  /// the original image doesn't cover the frame).
  final double scale;

  /// Pan applied after rotation + scale. Measured in source-image
  /// pixels relative to image center; the export pipeline does the
  /// math so the rendered image always fills the output frame.
  final Offset offset;

  /// Identity (no transform).
  static const MediaTransform identity =
      MediaTransform._raw(rotation: 0, scale: 1, offset: Offset.zero);

  /// Maximum straighten angle in either direction (±15°). Narrow on
  /// purpose — "straighten the horizon," not "rotate the photo."
  static const double maxRotation = math.pi / 12; // 15°

  /// Scale bounds. Lower bound is 1.0 so we never show empty pixels
  /// in the frame; upper bound is a generous 3× for manual reframing.
  static const double minScale = 1.0;
  static const double maxScale = 3.0;

  const MediaTransform._raw({
    required this.rotation,
    required this.scale,
    required this.offset,
  });

  /// Canonical constructor. Clamps rotation and scale to sane bounds.
  /// The slider and pinch gestures can briefly produce out-of-range
  /// values during a drag; clamping here keeps persisted state sane.
  factory MediaTransform({
    double rotation = 0,
    double scale = 1,
    Offset offset = Offset.zero,
  }) {
    final r = rotation.clamp(-maxRotation, maxRotation);
    final s = scale.clamp(minScale, maxScale);
    return MediaTransform._raw(rotation: r, scale: s, offset: offset);
  }

  /// True when this transform is an exact no-op. Used to skip the
  /// transform pass entirely in [applyFilterToImage] and to decide
  /// whether to show the Reset button in the UI.
  bool get isIdentity => rotation == 0 && scale == 1 && offset == Offset.zero;

  /// Minimum scale required so a rotated image fully covers its
  /// original frame (no empty triangles in the corners). Derived from
  /// the rotated bounding box of a `w × h` rectangle.
  ///
  /// For a frame with aspect `a = w / h` and rotation `θ`:
  ///   required_scale = max(
  ///     |cos θ| + |sin θ| / a,   // width constraint
  ///     |cos θ| + |sin θ| · a,   // height constraint
  ///   )
  ///
  /// At θ=0 both terms collapse to 1.0. The scale grows monotonically
  /// with |θ|.
  static double minScaleForRotation(double rotation, double aspect) {
    final absSin = math.sin(rotation.abs());
    final absCos = math.cos(rotation);
    final w = absCos + absSin / aspect;
    final h = absCos + absSin * aspect;
    return math.max(w, h);
  }

  MediaTransform copyWith({
    double? rotation,
    double? scale,
    Offset? offset,
  }) {
    return MediaTransform(
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      offset: offset ?? this.offset,
    );
  }

  Map<String, dynamic> toJson() => {
        'rotation': rotation,
        'scale': scale,
        'offset_x': offset.dx,
        'offset_y': offset.dy,
      };

  factory MediaTransform.fromJson(Map<String, dynamic> json) => MediaTransform(
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
        scale: (json['scale'] as num?)?.toDouble() ?? 1,
        offset: Offset(
          (json['offset_x'] as num?)?.toDouble() ?? 0,
          (json['offset_y'] as num?)?.toDouble() ?? 0,
        ),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaTransform &&
          other.rotation == rotation &&
          other.scale == scale &&
          other.offset == offset;

  @override
  int get hashCode => Object.hash(rotation, scale, offset);

  @override
  String toString() => 'MediaTransform(r=$rotation, s=$scale, o=$offset)';
}
