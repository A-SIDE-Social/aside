import 'dart:io';

import 'package:video_compress/video_compress.dart';

import '../config/constants.dart';

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

class PostVideoValidationException implements Exception {
  final String message;
  const PostVideoValidationException(this.message);
}

/// Picker duration options constrain recording, not every library import.
/// Read the actual file; unknown duration must not bypass the post limit.
Future<void> validatePostVideoDuration(String path) async {
  double? milliseconds;
  try {
    milliseconds = (await VideoCompress.getMediaInfo(path)).duration;
  } catch (_) {
    // Present a useful message without exposing native errors or file paths.
  }
  if (milliseconds == null || !milliseconds.isFinite || milliseconds <= 0) {
    throw const PostVideoValidationException(
      'We couldn’t check this video’s length. Please choose another video.',
    );
  }
  if (milliseconds > AppLimits.maxVideoPostSeconds * 1000) {
    throw const PostVideoValidationException(
      'Videos can be up to ${AppLimits.maxVideoPostSeconds ~/ 60} minutes. Trim this video in your photo library, then choose it again.',
    );
  }
}
