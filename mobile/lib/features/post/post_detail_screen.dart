import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../core/network/api_client.dart' show ApiException;
import '../../widgets/widgets.dart';
import '../../providers/providers.dart';
import '../../models/models.dart';

/// Provider that fetches a single post by ID.
final _postProvider =
    FutureProvider.autoDispose.family<Post, String>((ref, postId) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getPost(postId);
  return Post.fromJson(data as Map<String, dynamic>);
});

class PostDetailScreen extends ConsumerStatefulWidget {
  final String postId;

  const PostDetailScreen({super.key, required this.postId});

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  final _commentController = TextEditingController();
  final _commentFocusNode = FocusNode();
  bool _isSending = false;
  String? _editingCommentId;

  /// The comment the user is replying to, if any. Stored as the full
  /// Comment so the chip above the composer can render the
  /// "Replying to {name}" label without another lookup, and the
  /// `@{displayName} ` text prefix stays accurate.
  Comment? _replyingTo;

  double _dragOffset = 0;
  bool _isDismissing = false;
  bool _atTop = true;

  // Local like state for instant feedback without waiting for re-fetch
  bool? _isLikedOverride;
  int? _likeCountOverride;

  // Local reaction override — when non-null, takes precedence over
  // post.reactions for rendering. Set after a successful toggle via
  // the API (we replace with the server's authoritative response).
  // Stays in sync with the feed provider via the parallel call to
  // feedNotifier.toggleReaction below.
  List<PostReaction>? _reactionsOverride;

  @override
  void dispose() {
    _commentController.dispose();
    _commentFocusNode.dispose();
    super.dispose();
  }

  /// Enter reply mode: prefill "@{displayName} " and focus the
  /// composer. The FK ([_replyingTo.id]) is the backend source of
  /// truth for who gets notified — the text prefix is just a
  /// convention. Mirrors `_startReply` in [comments_sheet.dart].
  void _startReply(Comment parent) {
    setState(() {
      _replyingTo = parent;
      _editingCommentId = null;
      final prefix = '@${parent.displayName} ';
      _commentController.text = prefix;
      _commentController.selection = TextSelection.fromPosition(
        TextPosition(offset: prefix.length),
      );
    });
    _commentFocusNode.requestFocus();
  }

  /// Cancel reply mode. Strip the leading "@{displayName} " prefix if
  /// it's still intact — otherwise leave whatever the user typed.
  void _cancelReply() {
    final parent = _replyingTo;
    setState(() => _replyingTo = null);
    if (parent == null) return;
    final prefix = '@${parent.displayName} ';
    if (_commentController.text.startsWith(prefix)) {
      final rest = _commentController.text.substring(prefix.length);
      _commentController.text = rest;
      _commentController.selection = TextSelection.fromPosition(
        TextPosition(offset: rest.length),
      );
    }
  }

  Future<void> _toggleLike(Post post) async {
    final wasLiked = _isLikedOverride ?? post.isLiked;
    final oldCount = _likeCountOverride ?? post.likeCount;
    final newCount = wasLiked ? oldCount - 1 : oldCount + 1;

    setState(() {
      _isLikedOverride = !wasLiked;
      _likeCountOverride = newCount < 0 ? 0 : newCount;
    });

    // Keep feed in sync
    ref.read(feedNotifierProvider.notifier).toggleLike(post.id);

    try {
      final api = ref.read(apiServiceProvider);
      if (wasLiked) {
        await api.unlikePost(post.id);
      } else {
        await api.likePost(post.id);
      }
    } catch (_) {
      // Revert local override
      if (mounted) {
        setState(() {
          _isLikedOverride = wasLiked;
          _likeCountOverride = oldCount;
        });
      }
    }
  }

  /// Apply local like + reaction overrides to a post for rendering.
  Post _withLikeOverride(Post post) {
    if (_isLikedOverride == null &&
        _likeCountOverride == null &&
        _reactionsOverride == null) {
      return post;
    }
    return post.copyWith(
      likeCount: _likeCountOverride,
      isLiked: _isLikedOverride,
      reactions: _reactionsOverride,
    );
  }

  /// Toggle an emoji reaction on the detail screen. Mirrors the
  /// _toggleLike pattern: optimistic local override + parallel call
  /// to feedNotifier so the cached feed updates too. Replaces the
  /// override with the server's canonical reactions list when the
  /// toggle round-trips successfully.
  Future<void> _toggleReaction(Post post, String emoji) async {
    final current = _reactionsOverride ?? post.reactions;
    final next = <PostReaction>[];
    var found = false;
    for (final r in current) {
      if (r.emoji != emoji) {
        next.add(r);
        continue;
      }
      found = true;
      final newCount = r.reactedByMe ? r.count - 1 : r.count + 1;
      if (newCount > 0) {
        next.add(r.copyWith(
          count: newCount,
          reactedByMe: !r.reactedByMe,
        ));
      }
    }
    if (!found) {
      next.add(PostReaction(emoji: emoji, count: 1, reactedByMe: true));
    }
    setState(() => _reactionsOverride = next);

    // Keep feed in sync — fire-and-forget; feed provider does its
    // own optimistic + server-replace cycle.
    ref.read(feedNotifierProvider.notifier).toggleReaction(post.id, emoji);

    try {
      final api = ref.read(apiServiceProvider);
      final serverReactions = await api.togglePostReaction(post.id, emoji);
      if (!mounted) return;
      final parsed = serverReactions
          .map((r) => PostReaction.fromJson(r as Map<String, dynamic>))
          .toList();
      setState(() => _reactionsOverride = parsed);
    } catch (_) {
      // Optimistic guess stays. Next provider invalidation re-syncs.
    }
  }

  void _cancelEdit() {
    setState(() {
      _editingCommentId = null;
      _commentController.clear();
    });
  }

  Future<void> _sendComment() async {
    final body = _commentController.text.trim();
    if (body.isEmpty || _isSending) return;

    setState(() => _isSending = true);

    try {
      final api = ref.read(apiServiceProvider);
      final isNewComment = _editingCommentId == null;
      if (_editingCommentId != null) {
        await api.editComment(_editingCommentId!, body);
        _editingCommentId = null;
      } else {
        await api.createComment(
          widget.postId,
          body,
          replyToCommentId: _replyingTo?.id,
        );
      }
      _commentController.clear();
      setState(() => _replyingTo = null);
      if (mounted) FocusScope.of(context).unfocus();
      ref.invalidate(commentsProvider(widget.postId));
      if (isNewComment) {
        ref
            .read(feedNotifierProvider.notifier)
            .incrementCommentCount(widget.postId);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send comment: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _deletePost(String postId) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.deletePost(postId);
      if (mounted) {
        // Remove from feed immediately before popping
        ref.read(feedNotifierProvider.notifier).removePost(postId);
        // Also invalidate user posts so profile grid updates
        final currentUser = ref.read(authProvider).user;
        if (currentUser != null) {
          ref.invalidate(userPostsProvider(currentUser.id));
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Post deleted')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete post: $e')),
        );
      }
    }
  }

  Future<void> _editCaption(String postId, String caption) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.editPostCaption(postId, caption);
      ref.invalidate(_postProvider(postId));
      // Refresh feed and profile to reflect caption change
      ref.read(feedNotifierProvider.notifier).refresh();
      final currentUser = ref.read(authProvider).user;
      if (currentUser != null) {
        ref.invalidate(userPostsProvider(currentUser.id));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Caption updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update caption: $e')),
        );
      }
    }
  }

  Future<void> _deleteComment(Comment comment) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.deleteComment(comment.id);
      ref.invalidate(commentsProvider(widget.postId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete comment: $e')),
        );
      }
    }
  }

  void _showCommentActionSheet(Comment comment) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _editingCommentId = comment.id;
                  _commentController.text = comment.body;
                  _commentController.selection = TextSelection.fromPosition(
                    TextPosition(offset: comment.body.length),
                  );
                });
                // Focus the text field
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  FocusScope.of(context).requestFocus();
                });
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: AppColors.error),
              title: Text('Delete', style: TextStyle(color: AppColors.error)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteComment(comment);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteComment(Comment comment) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete comment?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteComment(comment);
            },
            child: Text(
              'Delete',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }

  /// Renders the error state when the post fetch fails. The most common
  /// way users land here is by tapping a push notification for a post
  /// that's since been deleted — the server returns 404, and showing a
  /// raw "ApiException(404): The requested resource was not found." is
  /// confusing. Detect 404 specifically and frame it as "this post is
  /// no longer available" with no Try Again button (retrying won't help
  /// — the post is gone). Other errors keep the retry path.
  Widget _buildPostError(Object error) {
    final isMissing = error is ApiException && error.statusCode == 404;
    if (isMissing) {
      return const ErrorView(
        icon: Icons.visibility_off_outlined,
        title: 'Post unavailable',
        message:
            'This post is no longer available. The author may have deleted it.',
      );
    }
    return ErrorView(
      message: error.toString(),
      onRetry: () => ref.invalidate(_postProvider(widget.postId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final postAsync = ref.watch(_postProvider(widget.postId));
    final commentsAsync = ref.watch(commentsProvider(widget.postId));
    final currentUser = ref.watch(authProvider).user;

    return Listener(
      onPointerUp: (_) {
        if (_isDismissing) {
          if (_dragOffset > 80) {
            context.pop();
          } else {
            setState(() {
              _dragOffset = 0;
              _isDismissing = false;
            });
          }
        }
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification) {
            _atTop = notification.metrics.pixels <= 0;
          }
          if (notification is OverscrollNotification &&
              _atTop &&
              notification.overscroll < 0) {
            setState(() {
              _isDismissing = true;
              _dragOffset =
                  (_dragOffset - notification.overscroll).clamp(0.0, 400.0);
            });
          }
          return false;
        },
        child: AnimatedContainer(
          duration:
              _isDismissing ? Duration.zero : const Duration(milliseconds: 200),
          transform: Matrix4.translationValues(0, _dragOffset, 0),
          child: Opacity(
              opacity: (1 - (_dragOffset / 400)).clamp(0.5, 1.0),
              child: Scaffold(
                appBar: AppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      } else {
                        context.go('/');
                      }
                    },
                  ),
                  elevation: 0,
                  scrolledUnderElevation: 0,
                ),
                body: Column(
                  children: [
                    Expanded(
                      child: postAsync.when(
                        data: (post) {
                          final displayPost = _withLikeOverride(post);
                          return CustomScrollView(
                            physics: const ClampingScrollPhysics(),
                            slivers: [
                              SliverToBoxAdapter(
                                child: Column(
                                  children: [
                                    PostCard(
                                      post: displayPost,
                                      showCommentButton: true,
                                      onLike: () => _toggleLike(post),
                                      onReact: (emoji) =>
                                          _toggleReaction(post, emoji),
                                      onUserTap: () => context
                                          .push('/profile/${post.userId}'),
                                      isOwn: post.userId == currentUser?.id,
                                      onEditCaption:
                                          post.userId == currentUser?.id
                                              ? (caption) =>
                                                  _editCaption(post.id, caption)
                                              : null,
                                      onDelete: post.userId == currentUser?.id
                                          ? () => _deletePost(post.id)
                                          : null,
                                    ),
                                    Divider(color: colors.borderSubtle),
                                  ],
                                ),
                              ),
                              commentsAsync.when(
                                data: (comments) {
                                  if (comments.isEmpty) {
                                    return SliverToBoxAdapter(
                                      child: Padding(
                                        padding: const EdgeInsets.all(32),
                                        child: Center(
                                          child: Text(
                                            'No comments yet',
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                        ),
                                      ),
                                    );
                                  }

                                  return SliverList.separated(
                                    itemCount: comments.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 4),
                                    itemBuilder: (context, index) {
                                      final comment = comments[index];
                                      final isOwn =
                                          comment.userId == currentUser?.id;
                                      return CommentTile(
                                        comment: comment,
                                        isOwn: isOwn,
                                        onLongPressOwn: isOwn
                                            ? () =>
                                                _showCommentActionSheet(comment)
                                            : null,
                                        onReply: () => _startReply(comment),
                                        onLikeToggle: () => ref
                                            .read(
                                                commentsProvider(widget.postId)
                                                    .notifier)
                                            .toggleLike(comment.id),
                                        onLikesLongPress: () =>
                                            showCommentLikesSheet(
                                                context, comment.id),
                                        // Post detail is a top-level screen, not a
                                        // sheet, so we just push the profile route
                                        // directly — no parent to pop first.
                                        onUserTap: () => context
                                            .push('/profile/${comment.userId}'),
                                        onMentionTap: comment.replyToUserId !=
                                                null
                                            ? () => context.push(
                                                '/profile/${comment.replyToUserId}')
                                            : null,
                                      );
                                    },
                                  );
                                },
                                loading: () => const SliverToBoxAdapter(
                                  child: Padding(
                                    padding: EdgeInsets.all(32),
                                    child: LoadingIndicator(),
                                  ),
                                ),
                                error: (error, _) => SliverToBoxAdapter(
                                  child: ErrorView(
                                    message: error.toString(),
                                    onRetry: () => ref.invalidate(
                                        commentsProvider(widget.postId)),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                        loading: () => const LoadingIndicator(),
                        error: (error, _) => _buildPostError(error),
                      ),
                    ),

                    // Edit mode banner
                    if (_editingCommentId != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        color: colors.surfaceAlt,
                        child: Row(
                          children: [
                            Icon(Icons.edit,
                                size: 14, color: colors.textTertiary),
                            const SizedBox(width: 6),
                            Text(
                              'Editing comment',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.textTertiary,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: _cancelEdit,
                              child: Icon(Icons.close,
                                  size: 18, color: colors.textTertiary),
                            ),
                          ],
                        ),
                      ),

                    // Reply mode chip (distinct from edit; replies are outbound).
                    // Mirrors the chip in comments_sheet.dart.
                    if (_replyingTo != null && _editingCommentId == null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        color: colors.surfaceAlt,
                        child: Row(
                          children: [
                            Icon(Icons.reply,
                                size: 14, color: colors.textTertiary),
                            const SizedBox(width: 6),
                            Text(
                              'Replying to ${_replyingTo!.displayName}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.textTertiary,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: _cancelReply,
                              child: Icon(Icons.close,
                                  size: 18, color: colors.textTertiary),
                            ),
                          ],
                        ),
                      ),

                    // Comment input bar
                    Container(
                      decoration: BoxDecoration(
                        color: colors.surface,
                        border: Border(
                          top: BorderSide(
                              color: colors.borderSubtle, width: 0.5),
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _commentController,
                                  focusNode: _commentFocusNode,
                                  decoration: InputDecoration(
                                    hintText: _editingCommentId != null
                                        ? 'Edit comment...'
                                        : 'Add a comment...',
                                    filled: true,
                                    fillColor: colors.surfaceAlt,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide(
                                        color: colors.border,
                                        width: 0.5,
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide(
                                        color: colors.border,
                                        width: 0.5,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide(
                                        color: colors.textTertiary,
                                        width: 0.5,
                                      ),
                                    ),
                                  ),
                                  textInputAction: TextInputAction.send,
                                  onSubmitted: (_) => _sendComment(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: _isSending
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: colors.textPrimary,
                                        ),
                                      )
                                    : Icon(
                                        _editingCommentId != null
                                            ? Icons.check_rounded
                                            : Icons.send_rounded,
                                        color: colors.textPrimary,
                                      ),
                                onPressed: _isSending ? null : _sendComment,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )),
        ),
      ),
    );
  }

  // Per-comment row rendering moved to the shared `CommentTile` widget
  // (lib/widgets/comment_tile.dart). Both this screen and the slide-up
  // comments sheet consume it so the two surfaces stay in lockstep.
  // Reply tap target, comment-like button, and "who liked this comment"
  // long-press all live there.
}
