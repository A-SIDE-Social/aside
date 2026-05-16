import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A pending in-app route produced by a notification tap. AsideApp watches this
/// and calls `router.go(...)` on the next frame, then clears it back to null.
///
/// This is the one-way channel between PushNotificationService (which has no
/// BuildContext) and the router. Using a tiny Notifier keeps the push service
/// free of direct GoRouter / BuildContext coupling so it can be invoked from
/// any isolate (foreground, background open, or cold start).
class PendingDeepLink extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? route) => state = route;
}

final pendingDeepLinkProvider =
    NotifierProvider<PendingDeepLink, String?>(PendingDeepLink.new);

/// Map a notification data payload (as delivered by FCM / APNs) to an in-app
/// route. Returns null when the payload doesn't match a known deep-link type,
/// so the caller can fall back to the default home behavior.
String? routeForNotificationData(Map<String, dynamic> data) {
  final type = data['type'];
  if (type is! String) return null;

  switch (type) {
    case 'inbound_follow':
    case 'new_mutual':
      // Both go to Connections — inbound_follow lands on the Requests
      // section at the top, new_mutual shows them in the Connected section.
      return '/connections';
    case 'new_post':
      // Build 38: route new_post notifications to the feed top
      // rather than the post detail screen. Detail page exists but
      // is awkward for non-owners — most users hitting this push
      // expect to see the post in feed context with the rest of
      // their network's activity around it. The post will be at
      // (or near) the top of the feed for them too.
      return '/';
    case 'comment':
    case 'comment_reply':
      // Comment activity stays on the post detail — recipient is
      // (almost always) the post owner who can read the comment
      // thread there. 'comment' is also handled here because older
      // server builds accidentally sent `type: 'new_post'` for
      // comment pushes; backwards compatibility kept that branch
      // forgiving. Scroll-to-comment for replies is a future
      // improvement.
      final postId = data['post_id'];
      if (postId is String && postId.isNotEmpty) return '/post/$postId';
      return null;
    case 'dm':
      final conversationId = data['conversation_id'];
      if (conversationId is String && conversationId.isNotEmpty) {
        return '/conversations/$conversationId';
      }
      return null;
    default:
      return null;
  }
}
