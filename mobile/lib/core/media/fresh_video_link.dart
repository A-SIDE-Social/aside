import 'package:video_player/video_player.dart';

import '../cache/image_cache_manager.dart';
import '../network/api_service.dart';

/// Opens a video, asking for a new link once if the first attempt fails.
///
/// Links with a query string can expire while a screen stays open. Links
/// without one don't, so a failure there isn't retried and makes no API call.
Future<T> openWithFreshLink<T>(
  String url, {
  required Future<T> Function(String url) open,
  required Future<String?> Function() freshUrl,
}) async {
  try {
    return await open(url);
  } catch (_) {
    if (!url.contains('?')) rethrow;
    String? fresh;
    try {
      fresh = await freshUrl();
    } catch (_) {
      fresh = null;
    }
    if (fresh == null || fresh == url) rethrow;
    return open(fresh);
  }
}

/// Finds the current link for the file at [url] within a post.
Future<String?> freshPostMediaUrl(
  ApiService api,
  String postId,
  String url,
) async {
  final post = await api.getPost(postId);
  final media = post is Map ? post['media'] : null;
  if (media is! List) return null;
  final currentFile = mediaCacheKey(url);
  for (final item in media) {
    final itemUrl = item is Map ? item['media_url'] : null;
    if (itemUrl is String && mediaCacheKey(itemUrl) == currentFile) {
      return itemUrl;
    }
  }
  return null;
}

/// Opens and initializes a network video, renewing an expired link once.
Future<VideoPlayerController> openPostVideo(
  ApiService Function() api,
  String postId,
  String url,
) {
  return openWithFreshLink<VideoPlayerController>(
    url,
    open: (link) async {
      final controller = VideoPlayerController.networkUrl(Uri.parse(link));
      try {
        await controller.initialize();
        return controller;
      } catch (_) {
        await controller.dispose();
        rethrow;
      }
    },
    freshUrl: () => freshPostMediaUrl(api(), postId, url),
  );
}
