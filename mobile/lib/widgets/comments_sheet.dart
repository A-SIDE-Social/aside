import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_colors.dart';
import '../models/comment.dart';
import '../providers/providers.dart';
import 'comment_tile.dart';
import 'likes_sheet.dart';
import 'speech_input_button.dart';

/// Shows a draggable comment sheet for a post. Auto-focuses the text field.
void showCommentsSheet(BuildContext context, String postId) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _CommentsSheet(postId: postId),
  );
}

class _CommentsSheet extends ConsumerStatefulWidget {
  final String postId;
  const _CommentsSheet({required this.postId});

  @override
  ConsumerState<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<_CommentsSheet> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _isSending = false;
  String? _editingCommentId;

  /// The comment the user is currently replying to, if any. Stored as
  /// the full Comment (not just id) so we can render the chip above the
  /// composer without another lookup, and so the `@{displayName} `
  /// prefix stays accurate if multiple people share similar names.
  Comment? _replyingTo;

  @override
  void initState() {
    super.initState();
    // Auto-focus the text field after the sheet animates in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _cancelEdit() {
    setState(() {
      _editingCommentId = null;
      _controller.clear();
    });
  }

  /// Enter reply mode: prefill "@{displayName} " and focus the composer.
  /// The FK ([_replyingTo.id]) is the backend source of truth for who
  /// gets notified — the text prefix is just a convention.
  void _startReply(Comment parent) {
    setState(() {
      _replyingTo = parent;
      _editingCommentId = null;
      final prefix = '@${parent.displayName} ';
      _controller.text = prefix;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: prefix.length),
      );
    });
    _focusNode.requestFocus();
  }

  /// Cancel reply mode. Strip the leading "@{displayName} " prefix if
  /// it's still intact — otherwise leave whatever the user typed.
  void _cancelReply() {
    final parent = _replyingTo;
    setState(() => _replyingTo = null);
    if (parent == null) return;
    final prefix = '@${parent.displayName} ';
    if (_controller.text.startsWith(prefix)) {
      final rest = _controller.text.substring(prefix.length);
      _controller.text = rest;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: rest.length),
      );
    }
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    try {
      final api = ref.read(apiServiceProvider);
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
      _controller.clear();
      setState(() => _replyingTo = null);
      ref.invalidate(commentsProvider(widget.postId));
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

  Future<void> _delete(Comment comment) async {
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

  void _showActionSheet(Comment comment) {
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
                  _controller.text = comment.body;
                  _controller.selection = TextSelection.fromPosition(
                    TextPosition(offset: comment.body.length),
                  );
                });
                _focusNode.requestFocus();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: AppColors.error),
              title: Text('Delete', style: TextStyle(color: AppColors.error)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(comment);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(Comment comment) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete comment?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _delete(comment);
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

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final commentsAsync = ref.watch(commentsProvider(widget.postId));
    final currentUser = ref.watch(authProvider).user;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Handle
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
                'Comments',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Divider(height: 0.5, thickness: 0.5, color: colors.border),

            // Comments list
            Expanded(
              child: commentsAsync.when(
                data: (comments) {
                  if (comments.isEmpty) {
                    return Center(
                      child: Text(
                        'No comments yet',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: comments.length,
                    itemBuilder: (context, index) {
                      final comment = comments[index];
                      final isOwn = comment.userId == currentUser?.id;
                      return CommentTile(
                        comment: comment,
                        isOwn: isOwn,
                        onLongPressOwn:
                            isOwn ? () => _showActionSheet(comment) : null,
                        onReply: () => _startReply(comment),
                        onLikeToggle: () => ref
                            .read(commentsProvider(widget.postId).notifier)
                            .toggleLike(comment.id),
                        onLikesLongPress: () =>
                            showCommentLikesSheet(context, comment.id),
                        // Sheet pops itself before pushing a profile
                        // route so the user doesn't return to a
                        // half-state where the sheet is still on top.
                        onUserTap: () {
                          Navigator.pop(context);
                          context.push('/profile/${comment.userId}');
                        },
                        onMentionTap: comment.replyToUserId != null
                            ? () {
                                Navigator.pop(context);
                                context
                                    .push('/profile/${comment.replyToUserId}');
                              }
                            : null,
                      );
                    },
                  );
                },
                loading: () => const Center(
                  child: CircularProgressIndicator(),
                ),
                error: (error, _) => Center(
                  child: Text('Failed to load comments'),
                ),
              ),
            ),

            // Edit mode banner
            if (_editingCommentId != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: colors.surfaceAlt,
                child: Row(
                  children: [
                    Icon(Icons.edit, size: 14, color: colors.textTertiary),
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
            if (_replyingTo != null && _editingCommentId == null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: colors.surfaceAlt,
                child: Row(
                  children: [
                    Icon(Icons.reply, size: 14, color: colors.textTertiary),
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

            // Input bar
            Container(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  top: BorderSide(color: colors.borderSubtle, width: 0.5),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          // Comment field grows with content (1..5 lines)
                          // so a long speech-to-text dictation wraps and
                          // becomes editable line-by-line instead of one
                          // very wide horizontally-scrolling line that's
                          // hard to navigate for corrections.
                          minLines: 1,
                          maxLines: 5,
                          // Explicit text (not multiline) keeps the return
                          // key as the action key (show "send"), preserving
                          // submit-on-return. Multiline wrap is still
                          // produced by maxLines>1 + automatic soft wrap.
                          keyboardType: TextInputType.text,
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
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      SpeechInputButton(controller: _controller),
                      const SizedBox(width: 4),
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
                        onPressed: _isSending ? null : _send,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
