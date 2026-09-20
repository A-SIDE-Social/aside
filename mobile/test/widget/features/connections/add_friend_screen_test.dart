import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:aside/features/connections/add_friend_screen.dart';

void main() {
  Future<GoRouter> mount(WidgetTester tester) async {
    final router = GoRouter(initialLocation: '/add', routes: [
      GoRoute(path: '/add', builder: (_, __) => const AddFriendScreen()),
      GoRoute(
          path: '/u/:slug',
          builder: (_, state) => Scaffold(body: Text('Preview ${state.uri}'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    return router;
  }

  testWidgets(
      'paste works without contacts permission and previews before sending',
      (tester) async {
    await mount(tester);
    await tester.enterText(
        find.byType(TextField), ' http://localhost:3000/k7m2pq9xj4n6/ ');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Preview /u/k7m2pq9xj4n6'), findsOneWidget);
  });
  testWidgets('legacy links keep the legacy route', (tester) async {
    await mount(tester);
    await tester.enterText(
        find.byType(TextField), 'http://localhost:3000/join/Ab12cd34ef56');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Preview /u/Ab12cd34ef56?legacy=1'), findsOneWidget);
  });
  testWidgets('malformed or foreign links stay editable', (tester) async {
    await mount(tester);
    await tester.enterText(
        find.byType(TextField), 'https://other.test/k7m2pq9xj4n6');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a friend’s invite link or 12-character code.'),
        findsOneWidget);
    await tester.enterText(find.byType(TextField), 'k7m2pq9xj4n6');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Preview /u/k7m2pq9xj4n6'), findsOneWidget);
  });
}
