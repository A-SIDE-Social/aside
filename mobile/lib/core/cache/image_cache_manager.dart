import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Shared on-disk cache for all `CachedNetworkImage` widgets in the app.
///
/// The default cache shipped with `cached_network_image` only keeps ~200
/// objects for 7 days. Bumping the limits cuts down on re-downloads when
/// users scroll feed/profile/conversations across many sessions.
class AppImageCacheManager {
  static const _key = 'kinImageCache';

  static final CacheManager instance = CacheManager(
    Config(
      _key,
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 1500,
    ),
  );
}

/// Cache key for a media URL: the URL without its query string.
///
/// A stored file never changes under the same path, but the parameters on its
/// URL can. Keying on the path keeps a cached file valid when they do. URLs
/// without a query keep their existing key, so current caches stay usable.
String mediaCacheKey(String url) {
  final queryStart = url.indexOf('?');
  return queryStart == -1 ? url : url.substring(0, queryStart);
}
