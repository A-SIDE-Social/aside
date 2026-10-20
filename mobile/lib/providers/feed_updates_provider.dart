import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import 'socket_provider.dart';

/// Post IDs waiting for a deliberate feed refresh. Socket and foreground
/// push delivery can overlap, so keep a set rather than counting messages.
class FeedUpdatesNotifier extends Notifier<Set<String>> {
  String? _userId;
  final Set<String> _received = {};
  @override
  Set<String> build() {
    final userId = ref.watch(authProvider.select((auth) => auth.user?.id));
    _userId = userId;
    _received.clear();
    if (userId != null) {
      final subscription = ref.read(socketServiceProvider).newPosts.listen(
            (postId) => receive(postId),
          );
      ref.onDispose(subscription.cancel);
    }
    return const {};
  }

  void receive(String postId) {
    if (_userId == null || postId.isEmpty || !_received.add(postId)) return;
    // A delayed push for an already refreshed socket event is still a
    // duplicate. Bound this memory to recent events for long app sessions.
    if (_received.length > 256) _received.remove(_received.first);
    state = {...state, postId};
  }

  /// Only acknowledge events present when the request started. Posts that
  /// arrive during the request must keep their indicator until refreshed.
  void acknowledge(Iterable<String> postIds) {
    state = state.difference(postIds.toSet());
  }
}

final feedUpdatesProvider = NotifierProvider<FeedUpdatesNotifier, Set<String>>(
  FeedUpdatesNotifier.new,
);
