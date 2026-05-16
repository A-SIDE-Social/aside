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
