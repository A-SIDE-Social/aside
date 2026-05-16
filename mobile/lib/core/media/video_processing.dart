import 'dart:io';

import 'package:video_compress/video_compress.dart';

/// Strip metadata (including GPS/location) from a video file by re-muxing it.
///
/// Uses video_compress to produce a clean copy. The re-compression strips
/// container-level metadata including GPS coordinates. Falls back to the
/// original file on failure.
Future<File> stripVideoMetadata(String inputPath) async {
  try {
    final info = await VideoCompress.compressVideo(
      inputPath,
      quality: VideoQuality.HighestQuality,
      deleteOrigin: false,
      includeAudio: true,
    );
    if (info != null && info.file != null) {
      return info.file!;
    }
  } catch (_) {
    // Best effort — fall through to return original
  }
  return File(inputPath);
}
