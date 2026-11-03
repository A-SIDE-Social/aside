import 'package:flutter/material.dart';

import '../core/config/app_colors.dart';

/// Shown in place of a video that couldn't be loaded.
class VideoUnavailable extends StatelessWidget {
  final AppColorTokens colors;

  const VideoUnavailable({super.key, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.surfaceAlt,
      alignment: Alignment.center,
      child: Semantics(
        label: 'Video unavailable',
        child: const Icon(Icons.videocam_off_outlined, size: 32),
      ),
    );
  }
}
