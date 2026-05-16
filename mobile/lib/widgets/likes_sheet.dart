// Build 39: "Liked by" bottom sheet.
//
// Long-pressing a heart anywhere — on a post card or on a comment in
// the comments sheet — opens this. Same modal style as
// CommentsSheet so the surfaces feel like siblings: drag handle,
// title row, scrollable list of avatars + display names. Tap a row
// to push that user's profile.
//
// Source-of-truth endpoints:
//   GET /v1/posts/:id/likes      → list of {id, display_name, avatar_url}
//   GET /v1/comments/:id/likes   → same shape
//
// Both gated server-side: posts require mutual follow with the
// owner; comments inherit access from the comments-list endpoint
// upstream.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_colors.dart';
import '../models/user.dart';
import '../providers/providers.dart';
import 'avatar.dart';

/// Open the "Liked by" sheet for a post. Loads the list async and
/// shows a spinner while the request is in flight; renders an
/// empty state if nobody's liked it yet.
Future<void> showPostLikesSheet(BuildContext context, String postId) {
  return _show(context, _LikesSource.post(postId));
}

/// Open the "Liked by" sheet for a comment. Same UI as posts.
Future<void> showCommentLikesSheet(BuildContext context, String commentId) {
  return _show(context, _LikesSource.comment(commentId));
}

Future<void> _show(BuildContext context, _LikesSource source) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _LikesSheet(source: source),
  );
}

/// Tagged union — keeps the sheet itself agnostic to whether it's
/// loading post or comment likes; the source picks the right
/// endpoint at fetch time.
class _LikesSource {
  const _LikesSource._({this.postId, this.commentId});
  factory _LikesSource.post(String id) => _LikesSource._(postId: id);
  factory _LikesSource.comment(String id) => _LikesSource._(commentId: id);
  final String? postId;
  final String? commentId;

  bool get isComment => commentId != null;
}

class _LikesSheet extends ConsumerStatefulWidget {
  const _LikesSheet({required this.source});
  final _LikesSource source;

  @override
  ConsumerState<_LikesSheet> createState() => _LikesSheetState();
}

class _LikesSheetState extends ConsumerState<_LikesSheet> {
  late Future<List<User>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<User>> _load() async {
    final api = ref.read(apiServiceProvider);
    final raw = widget.source.isComment
        ? await api.getCommentLikes(widget.source.commentId!)
        : await api.getPostLikes(widget.source.postId!);
    return raw
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.textTertiary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Liked by',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Divider(height: 0.5, thickness: 0.5, color: colors.border),
            Expanded(
              child: FutureBuilder<List<User>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        "Couldn't load likes",
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    );
                  }
                  final likers = snapshot.data ?? const <User>[];
                  if (likers.isEmpty) {
                    return Center(
                      child: Text(
                        'No likes yet',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: likers.length,
                    itemBuilder: (context, i) {
                      final u = likers[i];
                      return InkWell(
                        onTap: () {
                          Navigator.of(context).pop();
                          context.push('/profile/${u.id}');
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Avatar(
                                imageUrl: u.avatarUrl,
                                displayName: u.displayName,
                                size: 36,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  u.displayName,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
