import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../core/cache/image_cache_manager.dart';
import '../core/config/app_colors.dart';

class Avatar extends StatelessWidget {
  final String? imageUrl;
  final String displayName;
  final double size;

  const Avatar({
    super.key,
    this.imageUrl,
    required this.displayName,
    this.size = 40,
  });

  String get _initial =>
      displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cachePx = (size * dpr).round();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: colors.border,
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl != null && imageUrl!.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: imageUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheManager: AppImageCacheManager.instance,
              // Only constrain one axis so the decode preserves the source
              // aspect ratio. Passing both memCacheWidth AND memCacheHeight
              // forces Flutter to decode at exactly those dimensions (see
              // ui.instantiateImageCodec), which distorts non-square avatars
              // into squares — BoxFit.cover then can't recover the original
              // shape because the bitmap is already stretched. Giving only
              // the width lets the decode keep the aspect ratio, and the
              // parent Container + BoxFit.cover handle the center-crop.
              memCacheWidth: cachePx,
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              placeholder: (context, url) => _placeholder(colors),
              errorWidget: (context, url, error) => _placeholder(colors),
            )
          : _placeholder(colors),
    );
  }

  Widget _placeholder(AppColorTokens colors) {
    return Container(
      color: colors.surfaceAlt,
      alignment: Alignment.center,
      child: Text(
        _initial,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w500,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}
