import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/comment.dart';
import 'api_provider.dart';

/// Comments for a single post, with optimistic like-toggle support.
///
/// Riverpod 3 family Notifier — the `postId` is captured via the
/// family factory; `build()` kicks off the load and returns
/// `AsyncValue.loading()`. Call sites that previously mutated via
/// `ref.invalidate(commentsProvider(postId))` still work — invalidation
/// disposes the notifier and reloads on next watch.
///
/// The `toggleLike` optimistic flip mirrors `FeedNotifier.toggleLike`
/// (lib/providers/feed_provider.dart ~108–140).
class CommentsNotifier extends Notifier<AsyncValue<List<Comment>>> {
  CommentsNotifier(this._postId);

  final String _postId;

  @override
  AsyncValue<List<Comment>> build() {
    _load();
    return const AsyncValue.loading();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.getComments(_postId);
      final list = data as List<dynamic>;
      state = AsyncValue.data(
        list.map((e) => Comment.fromJson(e as Map<String, dynamic>)).toList(),
      );
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Force a reload from the server (used after new comments / edits
  /// where the optimistic path can't stitch the new row in).
  Future<void> refresh() => _load();

  /// Optimistic like/unlike toggle. Flips the local state immediately,
  /// then fires the API call; reverts on failure.
  Future<void> toggleLike(String commentId) async {
    final current = state.value;
    if (current == null) return;

    final target = current.firstWhere(
      (c) => c.id == commentId,
      orElse: () => current.first,
    );
    if (target.id != commentId) return;

    final wasLiked = target.isLiked;
    final newCount = wasLiked ? target.likeCount - 1 : target.likeCount + 1;

    state = AsyncValue.data(current.map((c) {
      if (c.id != commentId) return c;
      return c.copyWith(
        isLiked: !wasLiked,
        likeCount: newCount < 0 ? 0 : newCount,
      );
    }).toList());

    try {
      final api = ref.read(apiServiceProvider);
      if (wasLiked) {
        await api.unlikeComment(commentId);
      } else {
        await api.likeComment(commentId);
      }
    } catch (_) {
      // Revert on failure — read fresh state in case something else
      // (another user's like, a delete) landed in between.
      final reverted = state.value;
      if (reverted == null) return;
      state = AsyncValue.data(reverted.map((c) {
        if (c.id != commentId) return c;
        return c.copyWith(
          isLiked: wasLiked,
          likeCount: target.likeCount,
        );
      }).toList());
    }
  }
}

/// Family provider keyed by post id. Preserves the previous
/// `commentsProvider(postId)` ergonomics; callers' existing
/// `ref.invalidate(commentsProvider(postId))` calls still trigger
/// a fresh reload.
final commentsProvider = NotifierProvider.family<CommentsNotifier,
    AsyncValue<List<Comment>>, String>(CommentsNotifier.new);
