import 'package:flutter_test/flutter_test.dart';
import 'package:aside/core/platform/deep_link.dart';

void main() {
  const owner = '00000000-0000-0000-0000-000000000001';
  const post = '00000000-0000-0000-0000-000000000002';
  test('widget opens its exact post only in the matching account', () {
    final uri = Uri.parse('aside://post/$post?account=$owner');
    expect(routeForWidgetUri(uri, currentUserId: owner), '/post/$post');
    expect(routeForWidgetUri(uri, currentUserId: null), isNull);
    expect(routeForWidgetUri(uri, currentUserId: 'other'), isNull);
    expect(
        routeForWidgetUri(Uri.parse('aside://widgets'), currentUserId: owner),
        '/settings/widgets');
  });
  test(
      'rejects malformed paths, credentials, extra arguments and duplicate accounts',
      () {
    for (final url in [
      'https://post/$post?account=$owner',
      'aside://post/not-a-post?account=$owner',
      'aside://post/$post/extra?account=$owner',
      'aside://post/$post?account=$owner&account=other',
      'aside://post/$post?account=$owner&redirect=https://example.test',
      'aside://post/$post?account=$owner#fragment',
      'aside://user@post/$post?account=$owner',
    ]) {
      expect(routeForWidgetUri(Uri.parse(url), currentUserId: owner), isNull,
          reason: url);
    }
  });
}
