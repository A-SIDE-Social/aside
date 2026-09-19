import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:aside/core/platform/universal_link_service.dart';

class _Links extends Mock implements AppLinks {}

void main() {
  test('a warm tap during startup takes precedence over the initial link',
      () async {
    final links = _Links();
    final stream = StreamController<Uri>(sync: true);
    final initial = Completer<Uri?>();
    when(() => links.uriLinkStream).thenAnswer((_) => stream.stream);
    when(() => links.getInitialLink()).thenAnswer((_) => initial.future);
    final routes = <String>[];
    final service =
        UniversalLinkService(onDeepLink: routes.add, appLinks: links);
    final start = service.initialize();
    stream.add(Uri.parse('http://localhost/abcdefghijkl'));
    initial.complete(Uri.parse('http://localhost/k7m2pq9xj4n6'));
    await start;
    expect(routes, ['/u/abcdefghijkl']);
    await service.dispose();
    await stream.close();
  });
  test('disposal prevents a late startup callback', () async {
    final links = _Links();
    final stream = StreamController<Uri>();
    final initial = Completer<Uri?>();
    when(() => links.uriLinkStream).thenAnswer((_) => stream.stream);
    when(() => links.getInitialLink()).thenAnswer((_) => initial.future);
    final routes = <String>[];
    final service =
        UniversalLinkService(onDeepLink: routes.add, appLinks: links);
    final start = service.initialize();
    await service.dispose();
    initial.complete(Uri.parse('http://localhost/k7m2pq9xj4n6'));
    await start;
    expect(routes, isEmpty);
    await stream.close();
  });
}
