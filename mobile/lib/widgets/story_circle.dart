import 'package:flutter/material.dart';
import '../core/config/app_colors.dart';
import 'avatar.dart';

class StoryCircle extends StatelessWidget {
  final String? imageUrl;
  final String displayName;
  final bool hasStory;
  final VoidCallback? onTap;

  const StoryCircle({
    super.key,
    this.imageUrl,
    required this.displayName,
    this.hasStory = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);

    // Show first name only under story circles
    final firstName = displayName.split(' ').first;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              padding: const EdgeInsets.all(3),
              decoration: hasStory
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFF58529),
                          Color(0xFFDD2A7B),
                          Color(0xFF8134AF),
                        ],
                      ),
                    )
                  : BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: colors.borderSubtle,
                        width: 0.5,
                      ),
                    ),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colors.surface,
                    width: 2,
                  ),
                ),
                child: Avatar(
                  imageUrl: imageUrl,
                  displayName: displayName,
                  size: 56,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              firstName,
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
