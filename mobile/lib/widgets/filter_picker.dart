import 'dart:io';

import 'package:flutter/material.dart';
import '../core/config/app_colors.dart';
import '../core/media/film_filters.dart';
import '../core/media/media_transform.dart';
import 'filtered_image.dart';

/// Horizontal scrollable strip of filter previews. Each item shows a
/// thumbnail of the selected photo with the filter applied, plus the
/// filter name. Tapping selects it.
class FilterPicker extends StatelessWidget {
  /// Path to the photo used for filter previews (typically the first image).
  final String imagePath;

  /// Currently selected filter.
  final FilmFilter selectedFilter;

  /// Called when the user taps a filter.
  final ValueChanged<FilmFilter> onFilterChanged;

  /// Optional active transform — when set, each thumbnail's rotation
  /// matches what the user sees in the main preview, so picking a
  /// filter on a straightened photo doesn't show a misleadingly
  /// non-straightened thumbnail. Scale/offset are intentionally NOT
  /// applied: their units (preview-container px) don't translate to
  /// the 64px thumbnail frame without distortion. Rotation is unitless
  /// and composes correctly at any scale.
  final MediaTransform transform;

  const FilterPicker({
    super.key,
    required this.imagePath,
    required this.selectedFilter,
    required this.onFilterChanged,
    this.transform = MediaTransform.identity,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final filters = FilmFilters.all;

    return SizedBox(
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final filter = filters[index];
          final isSelected = filter.id == selectedFilter.id;

          return GestureDetector(
            onTap: () => onFilterChanged(filter),
            child: Column(
              children: [
                // Thumbnail with filter applied — preserves aspect ratio
                Container(
                  width: 64,
                  height: 72,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? colors.accent : colors.border,
                      width: isSelected ? 2 : 0.5,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: FilteredImage(
                      filter: filter,
                      width: 64,
                      height: 72,
                      child: Transform.rotate(
                        angle: transform.rotation,
                        child: Image.file(
                          File(imagePath),
                          width: 64,
                          height: 72,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // Filter name
                SizedBox(
                  width: 72,
                  child: Text(
                    filter.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected
                          ? colors.textPrimary
                          : colors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
