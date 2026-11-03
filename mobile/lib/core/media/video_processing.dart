import 'dart:io';

import 'package:video_compress/video_compress.dart';

import '../config/constants.dart';

/// Strip metadata (including GPS/location) from a video file by re-muxing it.
///
/// Uses video_compress to produce a clean copy. The re-compression strips
/// container-level metadata including GPS coordinates. Throws
/// [PostVideoValidationException] on failure rather than returning the
/// original, which could still contain the location it was recorded at.
Future<File> stripVideoMetadata(String inputPath) async {
  File? processed;
  try {
    final info = await VideoCompress.compressVideo(
      inputPath,
      quality: VideoQuality.HighestQuality,
      deleteOrigin: false,
      includeAudio: true,
    );
    processed = info?.file;
  } catch (_) {
    // Present a useful message without exposing native errors or file paths.
  }
  if (processed == null) {
    throw const PostVideoValidationException(
      'We couldn’t prepare this video for posting. Please try again, or choose another video.',
    );
  }
  return processed;
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

/// Checks the processed file before uploading it, so someone on a slow
/// connection isn't left waiting for an upload the server would reject.
Future<void> validatePostVideoSize(
  File file, {
  int maxBytes = AppLimits.maxVideoPostBytes,
}) async {
  if (await file.length() > maxBytes) {
    throw const PostVideoValidationException(
      'This video is too large to post. Videos can be up to 1 GB. Trim it in your photo library, then choose it again.',
    );
  }
}
