// Horizontal scrollable strip of emoji-reaction chips.
//
// Lives in the post card's action row, between the heart (pinned
// left) and the comment button (pinned right). Each chip = emoji
// + count below; selected (own reaction) state = subtle accent
// border. Tap to toggle your own reaction. Long-press to open the
// "who reacted" sheet for that emoji.
//
// Scrolls horizontally if the post has many distinct emojis. Empty
// when the post has no reactions yet — the parent renders the "+"
// affordance regardless, so the strip can collapse to zero width
// without losing the entry point.

import 'package:flutter/material.dart';

import '../core/config/app_colors.dart';
import '../models/post_reaction.dart';
import 'reaction_users_sheet.dart';

class ReactionsStrip extends StatelessWidget {
  final String postId;
  final List<PostReaction> reactions;

  /// Tap a chip → toggle that emoji for the current user. Caller
  /// handles the optimistic update + API call.
  final ValueChanged<String> onToggle;

  const ReactionsStrip({
    super.key,
    required this.postId,
    required this.reactions,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final colors = AppColors.of(context);

    // Single-row strip with chips that mirror the heart/comment
    // pattern: glyph + count side-by-side at the same baseline. The
    // earlier vertical-stack chip ("emoji over count") looked broken
    // next to the inline icon+count counterparts on either side of
    // the strip — the count number floated below the row's baseline.
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        physics: const ClampingScrollPhysics(),
        itemCount: reactions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final r = reactions[i];
          return _ReactionChip(
            reaction: r,
            colors: colors,
            onTap: () => onToggle(r.emoji),
            onLongPress: () => showReactionUsersSheet(
              context,
              postId: postId,
              emoji: r.emoji,
            ),
          );
        },
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final PostReaction reaction;
  final AppColorTokens colors;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ReactionChip({
    required this.reaction,
    required this.colors,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final selected = reaction.reactedByMe;
    // Inline chip: emoji + count side-by-side, baseline aligned with
    // the heart and comment buttons in the same row. No border —
    // selected (own reaction) state uses a subtle accent-tinted
    // background pill instead so the chip never resizes on toggle.
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? colors.accent.withValues(alpha: 0.10) : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(reaction.emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 5),
            Text(
              '${reaction.count}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                height: 1.0,
                color: selected ? colors.accent : colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
