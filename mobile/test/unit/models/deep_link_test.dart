import 'package:flutter_test/flutter_test.dart';

import 'package:aside/core/platform/deep_link.dart';

void main() {
  group('routeForNotificationData', () {
    test('returns connections route for inbound_follow type', () {
      final route = routeForNotificationData({
        'type': 'inbound_follow',
      });
      expect(route, '/connections');
    });

    test('returns connections route for new_mutual type', () {
      final route = routeForNotificationData({
        'type': 'new_mutual',
      });
      expect(route, '/connections');
    });

    // Build 38: new_post taps land on the feed top, not the post
    // detail page. Detail page exists but is awkward for non-owners
    // — readers want the post in feed context with the rest of their
    // network's activity around it.
    test('returns feed root for new_post regardless of post_id', () {
      expect(
        routeForNotificationData({
          'type': 'new_post',
          'post_id': 'abc-123',
        }),
        '/',
      );
      expect(
        routeForNotificationData({'type': 'new_post'}),
        '/',
      );
      expect(
        routeForNotificationData({
          'type': 'new_post',
          'post_id': '',
        }),
        '/',
      );
    });

    // Comment notifications STAY on the post detail (recipient is
    // the post owner; they can read the comment thread there).
    test('returns post detail for comment type with post_id', () {
      expect(
        routeForNotificationData({
          'type': 'comment',
          'post_id': 'xyz-789',
        }),
        '/post/xyz-789',
      );
    });

    test('returns post detail for comment_reply type with post_id', () {
      expect(
        routeForNotificationData({
          'type': 'comment_reply',
          'post_id': 'xyz-789',
        }),
        '/post/xyz-789',
      );
    });

    test('returns null for comment without post_id', () {
      expect(
        routeForNotificationData({'type': 'comment'}),
        isNull,
      );
    });

    test('returns conversation route for dm type with conversationId', () {
      final route = routeForNotificationData({
        'type': 'dm',
        'conversation_id': 'conv-1',
      });
      expect(route, '/conversations/conv-1');
    });

    test('returns null for dm without conversationId', () {
      final route = routeForNotificationData({
        'type': 'dm',
      });
      expect(route, isNull);
    });

    test('returns null for dm with empty conversationId', () {
      final route = routeForNotificationData({
        'type': 'dm',
        'conversation_id': '',
      });
      expect(route, isNull);
    });

    // Pin to the EXACT data payload shape produced by
    // src/firebase.ts notifyNewDM. If the server ever drops or
    // renames `conversation_id`, this test fails before the fact
    // shows up as "tapping DM lands on Home" in production.
    test('handles full notifyNewDM payload (incl. message_id + is_e2ee)', () {
      final route = routeForNotificationData({
        'type': 'dm',
        'conversation_id': '11111111-2222-3333-4444-555555555555',
        'message_id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        'is_e2ee': 'true',
      });
      expect(
        route,
        '/conversations/11111111-2222-3333-4444-555555555555',
      );
    });

    test('returns null for unknown type', () {
      final route = routeForNotificationData({
        'type': 'unknown_type',
      });
      expect(route, isNull);
    });

    test('returns null for empty data', () {
      final route = routeForNotificationData({});
      expect(route, isNull);
    });

    test('returns null when type is not a String', () {
      final route = routeForNotificationData({
        'type': 123,
      });
      expect(route, isNull);
    });
  });
}
