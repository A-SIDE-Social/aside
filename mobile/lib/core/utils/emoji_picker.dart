// Modal-bottom-sheet emoji picker. Wraps emoji_picker_flutter so the
// rest of the app sees a single Future<String?> async-pick API.
//
// Why a package, not a hidden TextField hack: iOS has no public API
// to force the system emoji keyboard from Dart — autofocusing a
// TextField just opens whatever keyboard the user last had, which
// usually isn't emoji. The package bundles the full Unicode emoji
// grid + searchable categories and renders consistently on iOS +
// Android.

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import 'package:aside/core/config/app_colors.dart';

/// Show the emoji picker as a modal bottom sheet anchored to the
/// bottom of the screen. Returns the user's pick as a single Unicode
/// emoji grapheme, or null if they dismissed without picking.
Future<String?> pickEmoji(BuildContext context) async {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.of(context).surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final colors = AppColors.of(ctx);
      // ~40% screen height keeps the picker from dominating but
      // shows ~3 rows of the grid plus the category bar.
      final pickerHeight = MediaQuery.of(ctx).size.height * 0.4;
      return SafeArea(
        top: false,
        child: SizedBox(
          height: pickerHeight,
          child: EmojiPicker(
            onEmojiSelected: (category, emoji) {
              Navigator.of(ctx).pop(emoji.emoji);
            },
            config: Config(
              height: pickerHeight,
              emojiViewConfig: EmojiViewConfig(
                backgroundColor: colors.surface,
                emojiSizeMax: 28,
              ),
              categoryViewConfig: CategoryViewConfig(
                backgroundColor: colors.surface,
                indicatorColor: colors.accent,
                iconColor: colors.textTertiary,
                iconColorSelected: colors.accent,
              ),
              bottomActionBarConfig: BottomActionBarConfig(
                backgroundColor: colors.surface,
                buttonColor: colors.surface,
                buttonIconColor: colors.textPrimary,
              ),
              searchViewConfig: SearchViewConfig(
                backgroundColor: colors.surface,
                buttonIconColor: colors.textPrimary,
              ),
            ),
          ),
        ),
      );
    },
  );
}
