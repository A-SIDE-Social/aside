// Shared per-comment row widget.
//
// Both the comments slide-up sheet (`comments_sheet.dart`) and the
// post detail screen (`post_detail_screen.dart`) render the same row
// shape: avatar, name + timestamp + (edited), body with optional
// @-mention prefix, "Reply" tap target on others' comments, heart-
// over-count on the right.
//
// Before this widget existed, the post detail screen had its own
// stripped-down row that was missing the Reply tap target and the
// comment-like button entirely — so users who deep-linked or pushed
// to post detail couldn't reply to or like comments at all. The two
// surfaces had drifted because each comment feature shipped only to
// the sheet. Centralising the row here means the next comment
// feature (or copy tweak) lands on both surfaces automatically.
//
// Parents still own:
//   - the comment list source (commentsProvider)
//   - the input + reply/edit mode state
//   - the action-sheet (Edit / Delete) that long-press opens
//   - the "who liked this comment" sheet
// CommentTile is purely the row rendering + tap dispatch.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/config/app_colors.dart';
import '../models/comment.dart';
import 'avatar.dart';
import 'linkified_text.dart';

class CommentTile extends StatelessWidget {
  final Comment comment;

  /// True when the comment belongs to the current user — drives
  /// long-press opening the Edit/Delete sheet, and suppresses the
  /// Reply tap target (you don't reply to yourself).
  final bool isOwn;

  /// Long-press handler for own comments. Parent typically opens an
  /// action sheet with Edit + Delete. Null on others' comments.
  final VoidCallback? onLongPressOwn;

  /// Tap handler for the Reply tap target shown beneath others'
  /// comments. Parent puts itself into reply mode (prefills the
  /// input field with `@{displayName} `).
  final VoidCallback onReply;

  /// Heart tap — toggles the like state via the comments notifier.
  final VoidCallback onLikeToggle;

  /// Heart long-press — opens the "Liked by" sheet.
  final VoidCallback onLikesLongPress;

  /// Tap on the avatar / display name. Parent decides whether to
  /// pop a containing sheet first before pushing the profile route
  /// (the slide-up sheet does, the post detail screen doesn't).
  final VoidCallback onUserTap;

  /// Tap on the @-mention prefix in a reply comment. Routes to the
  /// replied-to user's profile. Null when the comment isn't a reply
  /// or the parent doesn't want the prefix tappable.
  final VoidCallback? onMentionTap;

  const CommentTile({
    super.key,
    required this.comment,
    required this.isOwn,
    required this.onLongPressOwn,
    required this.onReply,
    required this.onLikeToggle,
    required this.onLikesLongPress,
    required this.onUserTap,
    this.onMentionTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return GestureDetector(
      onLongPress: onLongPressOwn,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onUserTap,
              child: Avatar(
                imageUrl: comment.avatarUrl,
                displayName: comment.displayName,
                size: 28,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row: name + timestamp + (edited).
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: GestureDetector(
                          onTap: onUserTap,
                          child: Text(
                            comment.displayName,
                            style: theme.textTheme.labelLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _timeAgo(comment.createdAt),
                        style: theme.textTheme.bodySmall,
                      ),
                      if (comment.updatedAt != null) ...[
                        const SizedBox(width: 4),
                        Text(
                          '(edited)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textTertiary,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  _CommentBody(
                    comment: comment,
                    style: theme.textTheme.bodyMedium,
                    accent: colors.accent,
                    onTapMention: onMentionTap,
                  ),
                  if (!isOwn) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: onReply,
                      child: Text(
                        'Reply',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.textTertiary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Right column: heart over count, mirrors the avatar's
            // left column. Top-aligned so the heart sits at the same
            // vertical position as the name. Long-press always fires
            // (no likeCount gate) — sheet renders an empty state if
            // nobody liked it yet.
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _CommentLikeButton(
                comment: comment,
                onTap: onLikeToggle,
                onLongPress: onLikesLongPress,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _timeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    if (diff.inDays < 365) return '${(diff.inDays / 7).floor()}w';
    return '${(diff.inDays / 365).floor()}y';
  }
}

/// Renders a comment body with an optional leading `@{displayName} `
/// prefix styled in the accent color when the comment is a reply.
/// If [onTapMention] is non-null, the prefix is also tappable —
/// routes to the replied-to user's profile.
///
/// Why not regex-match `@` in the body: display names collide,
/// change, and contain spaces. The server-provided `replyToDisplayName`
/// + FK gives an unambiguous styling target. If the body happens not
/// to start with the expected prefix (e.g. user deleted it before
/// sending), we fall back to the plain linkified body — nothing is
/// highlighted.
class _CommentBody extends StatelessWidget {
  final Comment comment;
  final TextStyle? style;
  final Color accent;
  final VoidCallback? onTapMention;

  const _CommentBody({
    required this.comment,
    required this.style,
    required this.accent,
    this.onTapMention,
  });

  @override
  Widget build(BuildContext context) {
    final replyName = comment.replyToDisplayName;
    if (replyName == null || comment.replyToCommentId == null) {
      return LinkifiedText(text: comment.body, style: style);
    }
    final prefix = '@$replyName ';
    if (!comment.body.startsWith(prefix)) {
      return LinkifiedText(text: comment.body, style: style);
    }
    final rest = comment.body.substring(prefix.length);

    final mentionRecognizer = onTapMention == null
        ? null
        : (TapGestureRecognizer()..onTap = onTapMention!);

    return RichText(
      text: TextSpan(
        style: style,
        children: [
          TextSpan(
            text: '@$replyName',
            style: style?.copyWith(
              color: accent,
              fontWeight: FontWeight.w600,
            ),
            recognizer: mentionRecognizer,
          ),
          const TextSpan(text: ' '),
          ...LinkifiedText.buildSpans(context, rest, style: style),
        ],
      ),
    );
  }
}

/// Heart icon + optional count. Filled when liked, outline otherwise.
/// Mirrors the post-card action button shape: same glyph family
/// (`favorite_rounded`), same count-only-when-greater-than-zero rule,
/// same accent / tertiary color split.
class _CommentLikeButton extends StatelessWidget {
  final Comment comment;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _CommentLikeButton({
    required this.comment,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        // Match the avatar's column width so the right side visually
        // mirrors the left.
        width: 28,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              comment.isLiked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              size: 20,
              color: comment.isLiked ? AppColors.error : colors.textTertiary,
            ),
            if (comment.likeCount > 0) ...[
              const SizedBox(height: 2),
              Text(
                '${comment.likeCount}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.textTertiary,
                  fontWeight: FontWeight.w500,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
