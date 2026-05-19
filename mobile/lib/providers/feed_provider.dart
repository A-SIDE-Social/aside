import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/app_group_channel.dart';
import '../models/post.dart';
import '../models/post_reaction.dart';
import 'api_provider.dart';
import 'auth_provider.dart';

/// Currently selected group filter for the feed. `null` means show all.
///
/// Tiny Notifier (replaces the Riverpod 2 `StateProvider<String?>`).
/// Call sites set the value with `ref.read(feedGroupFilterProvider.notifier).set(id)`.
class FeedGroupFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? groupId) => state = groupId;
}

final feedGroupFilterProvider =
    NotifierProvider<FeedGroupFilter, String?>(FeedGroupFilter.new);

/// Manages paginated feed loading with a "load more" cursor.
///
/// Riverpod 3 Notifier — `build()` returns `AsyncValue.loading()` and
/// kicks off the initial load. The notifier listens to
/// [feedGroupFilterProvider] internally and reloads on change rather
/// than being re-created (which would clear cached data on every
/// filter change).
class FeedNotifier extends Notifier<AsyncValue<List<Post>>> {
  String? _nextCursor;
  bool _hasMore = true;

  /// Whether the server reported older posts sitting behind the Free
  /// plan gate on the initial page. Used by the feed screen to decide
  /// if the paywall banner should appear at the end of the list.
  /// Set only by [loadInitial] — pagination doesn't change it.
  bool _hasOlderPosts = false;

  @override
  AsyncValue<List<Post>> build() {
    // Reload when the group filter changes — without re-creating the notifier.
    ref.listen<String?>(feedGroupFilterProvider, (_, __) {
      loadInitial();
    });
    // Schedule on a microtask so the first synchronous `state =`
    // inside loadInitial() runs after build() returns. Riverpod 3
    // throws "Tried to read the state of an uninitialized provider"
    // otherwise.
    // ignore: discarded_futures
    Future.microtask(loadInitial);
    return const AsyncValue.loading();
  }

  bool get hasMore => _hasMore;
  bool get hasOlderPosts => _hasOlderPosts;

  Future<void> loadInitial() async {
    state = const AsyncValue.loading();
    _nextCursor = null;
    _hasMore = true;
    _hasOlderPosts = false;

    try {
      final apiService = ref.read(apiServiceProvider);
      final groupId = ref.read(feedGroupFilterProvider);
      final data = await apiService.getFeed(groupId: groupId);
      final list = (data['posts'] as List<dynamic>?) ?? [];
      final posts =
          list.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();

      // Cursor is the created_at of the last post (server expects timestamptz,
      // not the post id). Send as ISO-8601 so Postgres can parse it.
      _nextCursor = posts.isNotEmpty
          ? posts.last.createdAt.toUtc().toIso8601String()
          : null;
      _hasMore = posts.length >= 20; // assume page size of 20
      _hasOlderPosts = data['has_older_posts'] as bool? ?? false;
      state = AsyncValue.data(posts);

      // Cache latest friend's photo for iOS widget
      _cacheWidgetImage(posts);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> loadMore() async {
    if (!_hasMore || _nextCursor == null) return;

    final current = state.value ?? [];
    try {
      final apiService = ref.read(apiServiceProvider);
      final groupId = ref.read(feedGroupFilterProvider);
      final data =
          await apiService.getFeed(before: _nextCursor, groupId: groupId);
      final list = (data['posts'] as List<dynamic>?) ?? [];
      final newPosts =
          list.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();

      _nextCursor = newPosts.isNotEmpty
          ? newPosts.last.createdAt.toUtc().toIso8601String()
          : null;
      _hasMore = newPosts.length >= 20;
      state = AsyncValue.data([...current, ...newPosts]);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Increment the comment count for a post in the local feed state.
  void incrementCommentCount(String postId) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(current.map((p) {
      if (p.id != postId) return p;
      return p.copyWith(commentCount: p.commentCount + 1);
    }).toList());
  }

  /// Optimistic emoji reaction toggle. Flips the chip locally
  /// (count +1/-1, reactedByMe flips) and replaces the post's
  /// reaction list with the server's authoritative response when it
  /// lands. On error the local state is left as the optimistic
  /// guess — the next feed refresh re-syncs.
  ///
  /// Why no revert on error: unlike toggleLike (which has a single
  /// scalar to revert), reactions list shape is harder to reason
  /// about under partial failure (which emoji exists + at what
  /// count). The server always returns the canonical post.reactions
  /// after a successful toggle, so success replaces; failure is
  /// rare enough that "guess stuck for one tick, refresh fixes it"
  /// is the right v1 trade-off.
  Future<List<PostReaction>?> toggleReaction(
      String postId, String emoji) async {
    final current = state.value;
    if (current != null) {
      final index = current.indexWhere((p) => p.id == postId);
      if (index != -1) {
        final post = current[index];
        final optimisticReactions =
            togglePostReactionList(post.reactions, emoji);

        state = AsyncValue.data(current.map((p) {
          if (p.id != postId) return p;
          return p.copyWith(reactions: optimisticReactions);
        }).toList());
      }
    }

    try {
      final api = ref.read(apiServiceProvider);
      final serverReactions = await api.togglePostReaction(postId, emoji);
      // Replace with the canonical server state.
      final parsed = serverReactions
          .map((r) => PostReaction.fromJson(r as Map<String, dynamic>))
          .toList();
      final latest = state.value;
      if (latest != null && latest.any((p) => p.id == postId)) {
        state = AsyncValue.data(latest.map((p) {
          if (p.id != postId) return p;
          return p.copyWith(reactions: parsed);
        }).toList());
      }
      return parsed;
    } catch (_) {
      // Optimistic guess stays; next refresh will re-sync. See
      // method-level comment for why.
      return null;
    }
  }

  /// Optimistic like/unlike toggle. Flips immediately, reverts on failure.
  Future<void> toggleLike(String postId) async {
    final current = state.value;
    if (current == null) return;

    final post =
        current.firstWhere((p) => p.id == postId, orElse: () => current.first);
    if (post.id != postId) return;

    final wasLiked = post.isLiked;
    final newCount = wasLiked ? post.likeCount - 1 : post.likeCount + 1;

    // Optimistic update
    state = AsyncValue.data(current.map((p) {
      if (p.id != postId) return p;
      return p.copyWith(
        isLiked: !wasLiked,
        likeCount: newCount < 0 ? 0 : newCount,
      );
    }).toList());

    try {
      final api = ref.read(apiServiceProvider);
      if (wasLiked) {
        await api.unlikePost(postId);
      } else {
        await api.likePost(postId);
      }
    } catch (_) {
      // Revert on failure
      final reverted = state.value;
      if (reverted == null) return;
      state = AsyncValue.data(reverted.map((p) {
        if (p.id != postId) return p;
        return p.copyWith(isLiked: wasLiked, likeCount: post.likeCount);
      }).toList());
    }
  }

  /// Remove a post from the local state immediately (optimistic delete).
  void removePost(String postId) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(current.where((p) => p.id != postId).toList());
  }

  /// Cache the first friend's post for the iOS widget (skip own posts).
  void _cacheWidgetImage(List<Post> posts) async {
    // Get user ID from auth state or App Group container
    String? currentUserId = ref.read(authProvider).user?.id;
    currentUserId ??= await AppGroupChannel.getUserId();

    final pick = pickWidgetImage(posts, currentUserId: currentUserId);
    if (pick != null) {
      AppGroupChannel.cacheWidgetImage(pick.imageUrl, pick.posterName);
    }
  }

  /// Refresh the feed from scratch.
  Future<void> refresh() => loadInitial();
}

/// Result of a widget-image pick — what URL to cache and whose name
/// to stamp on it. Null-returning pickers mean "no eligible post."
class WidgetImagePick {
  final String imageUrl;
  final String posterName;
  const WidgetImagePick(this.imageUrl, this.posterName);
}

/// Walks the feed and picks the first post eligible to show in the
/// iOS widget. Selection rules (stop on first match):
///
///   1. Skip any post by [currentUserId] — the widget is about your
///      friends, not yourself.
///   2. Skip text-only posts (`media.isEmpty`).
///   3. Within a post, prefer the first photo anywhere in the carousel.
///   4. If no photo, fall back to the first video that has a
///      `thumbnailUrl` (client-uploaded first-frame JPEG).
///   5. A post whose media is entirely videos without thumbnails
///      (legacy uploads predating the thumbnail_url column) is
///      skipped; the next qualifying post wins.
///
/// Pure and synchronous — exported for unit tests and kept
/// side-effect-free so tests don't need the AppGroupChannel native
/// bridge or an auth Ref.
WidgetImagePick? pickWidgetImage(
  List<Post> posts, {
  String? currentUserId,
}) {
  for (final post in posts) {
    if (currentUserId != null && post.userId == currentUserId) continue;
    if (post.media.isEmpty) continue;

    // Pass 1: first photo anywhere in the carousel.
    for (final m in post.media) {
      if (m.mediaType == 'photo') {
        return WidgetImagePick(m.mediaUrl, post.displayName);
      }
    }

    // Pass 2: first video thumbnail, if no photo.
    for (final m in post.media) {
      if (m.mediaType == 'video' &&
          m.thumbnailUrl != null &&
          m.thumbnailUrl!.isNotEmpty) {
        return WidgetImagePick(m.thumbnailUrl!, post.displayName);
      }
    }
    // Fall through: post has media but nothing renderable; try next.
  }
  return null;
}

final feedNotifierProvider =
    NotifierProvider<FeedNotifier, AsyncValue<List<Post>>>(FeedNotifier.new);
