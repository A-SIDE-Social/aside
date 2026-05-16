import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_image_compress/flutter_image_compress.dart';

import 'film_filters.dart';
import 'media_transform.dart';

/// Decoded grain texture, loaded once and reused across exports. Null
/// until the first filter with `grain > 0` is applied.
ui.Image? _grainImage;

Future<ui.Image> _loadGrainImage() async {
  if (_grainImage != null) return _grainImage!;
  final data = await rootBundle.load('assets/grain.png');
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  final frame = await codec.getNextFrame();
  return _grainImage = frame.image;
}

/// Result of compressing an image for upload.
class CompressedImage {
  final Uint8List bytes;
  final int width;
  final int height;

  const CompressedImage({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

/// Compresses a photo from disk to a JPEG sized for upload.
///
/// Resizes so the longest edge is at most [maxDimension] (default 1800px),
/// re-encodes as JPEG at [quality] (default 88). EXIF is stripped.
///
/// Target mirrors Instagram's current ~1440–1620px Q87 range with a bit
/// of headroom for zoom-in inspection. The dominant quality win for the
/// feed is elsewhere — we no longer cap `memCacheWidth` in PostCard, so
/// source resolution reaches the rasterizer on decode.
Future<CompressedImage> compressImageForUpload(
  String filePath, {
  int maxDimension = 1800,
  int quality = 88,
}) async {
  final compressed = await FlutterImageCompress.compressWithFile(
    filePath,
    minWidth: maxDimension,
    minHeight: maxDimension,
    quality: quality,
    format: CompressFormat.jpeg,
    keepExif: false,
  );

  // Fall back to the original bytes if compression returned null
  // (e.g. unsupported source format on this platform).
  final bytes = compressed ?? await File(filePath).readAsBytes();

  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final width = frame.image.width;
  final height = frame.image.height;
  frame.image.dispose();

  return CompressedImage(bytes: bytes, width: width, height: height);
}

/// Applies a [FilmFilter] and optional [MediaTransform] to image bytes.
///
/// Pipeline (canvas, in order):
///   1. Transform pass (if non-identity): translate to image center,
///      rotate, scale, apply user pan, translate back. The image is
///      drawn with the color filter baked in so rotated-empty corners
///      get filtered black rather than showing transparent pixels.
///   2. Grain pass (if any): tiled softLight noise.
///
/// Output dimensions always match input — preserving aspect ratio is
/// an intentional product constraint in v1. Straighten rotates pixels,
/// auto-zoom (applied by the preview UI into [transform.scale]) keeps
/// the frame filled.
///
/// Returns the original bytes unchanged if filter + transform are both
/// no-ops and there's no grain.
Future<Uint8List> applyFilterToImage(
  Uint8List imageBytes,
  FilmFilter filter, {
  MediaTransform transform = MediaTransform.identity,
}) async {
  // Only truly bypass the pipeline when nothing needs to change.
  if (filter.isNone && filter.grain == 0 && transform.isIdentity) {
    return imageBytes;
  }

  final codec = await ui.instantiateImageCodec(imageBytes);
  final frame = await codec.getNextFrame();
  final original = frame.image;
  final imgWidth = original.width;
  final imgHeight = original.height;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  // Paint for drawing the (possibly filtered) image. The color filter
  // is attached here so it bakes into the rotated pixels in one pass.
  //
  // FilterQuality.high uses a better sampling kernel than the default
  // (low = bilinear). With transforms this matters — rotated or scaled
  // output with default quality looks noticeably soft on edges. The
  // cost is a few ms of extra CPU per image, acceptable for export.
  final basePaint = ui.Paint()..filterQuality = ui.FilterQuality.high;
  if (!filter.isNone) basePaint.colorFilter = filter.toColorFilter();

  if (transform.isIdentity) {
    // Fast path: no rotation/scale/pan, draw at origin.
    canvas.drawImage(original, ui.Offset.zero, basePaint);
  } else {
    // Transform pass. Rotate + scale around the image center, then apply
    // user pan. The canvas state is saved/restored so the grain pass
    // below always operates in unrotated pixel space.
    final cx = imgWidth / 2.0;
    final cy = imgHeight / 2.0;
    canvas.save();
    canvas.translate(cx + transform.offset.dx, cy + transform.offset.dy);
    canvas.rotate(transform.rotation);
    canvas.scale(transform.scale);
    canvas.translate(-cx, -cy);
    canvas.drawImage(original, ui.Offset.zero, basePaint);
    canvas.restore();
  }

  // Grain pass (if any). The grain shader outputs opaque gray noise;
  // we premultiply its alpha by `filter.grain` via a modulate
  // ColorFilter, then blend with softLight. Per Porter–Duff, softLight
  // interpolates with dst proportional to src.alpha, so alpha=grain
  // gives a natural lerp between "no grain" and "full grain".
  //
  // Grain is drawn in post-transform pixel space so it doesn't inherit
  // the rotation — otherwise straightened photos would have tilted
  // grain, which looks wrong.
  if (filter.grain > 0) {
    final grain = await _loadGrainImage();
    final bounds =
        ui.Rect.fromLTWH(0, 0, imgWidth.toDouble(), imgHeight.toDouble());
    final shader = ui.ImageShader(
      grain,
      ui.TileMode.repeated,
      ui.TileMode.repeated,
      _matrix4Identity,
    );
    final grainPaint = ui.Paint()
      ..shader = shader
      ..blendMode = ui.BlendMode.softLight
      ..colorFilter = ui.ColorFilter.mode(
        ui.Color.fromRGBO(255, 255, 255, filter.grain),
        ui.BlendMode.modulate,
      );
    canvas.drawRect(bounds, grainPaint);
  }

  final picture = recorder.endRecording();
  final output = await picture.toImage(imgWidth, imgHeight);
  final pngData = await output.toByteData(format: ui.ImageByteFormat.png);

  original.dispose();
  output.dispose();

  final jpegBytes = await FlutterImageCompress.compressWithList(
    pngData!.buffer.asUint8List(),
    minWidth: imgWidth,
    minHeight: imgHeight,
    quality: 95,
    format: CompressFormat.jpeg,
    autoCorrectionAngle: false,
    rotate: 0,
  );

  return jpegBytes;
}

/// 4×4 identity matrix for `ui.ImageShader` transform. Defined once to
/// avoid allocating on every filter application.
final Float64List _matrix4Identity = Float64List.fromList(<double>[
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
]);
