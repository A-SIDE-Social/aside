import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:aside/features/auth/onboarding_contacts_screen.dart';
import 'package:aside/features/contacts/contact_sync_screen.dart';
import 'package:aside/features/connections/add_friend_screen.dart';
import 'package:aside/providers/api_provider.dart';
import '../../../helpers/mocks.dart';

void main() {
  const channel = MethodChannel('com.lab1908.instadamn/contacts');
  for (final onboarding in [true, false]) {
    testWidgets(
        'denied contacts still allows manual invites (${onboarding ? 'onboarding' : 'settings'})',
        (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        calls.add(call.method);
        return false;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final api = MockApiService();
      final router = GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (_, __) => onboarding
                ? const OnboardingContactsScreen()
                : const ContactSyncScreen()),
        GoRoute(
            path: '/connections/add',
            builder: (_, __) => const AddFriendScreen()),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(ProviderScope(
          overrides: [apiServiceProvider.overrideWithValue(api)],
          child: MaterialApp.router(routerConfig: router)));
      await tester.ensureVisible(find.text('Upload & find friends'));
      await tester.tap(find.text('Upload & find friends'));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Contacts access wasn’t allowed. Use an invite link or code instead.'),
          findsOneWidget);
      await tester.ensureVisible(find.text('Use an invite link or code'));
      await tester.tap(find.text('Use an invite link or code'));
      await tester.pumpAndSettle();
      expect(find.text('Have an invite?'), findsOneWidget);
      expect(calls, ['requestPermission']);
      verifyNever(() => api.syncContacts(any()));
    });

    testWidgets(
        'late contact permission response after leaving is harmless ($onboarding)',
        (tester) async {
      final permission = Completer<bool>();
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) => permission.future);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
              home: onboarding
                  ? const OnboardingContactsScreen()
                  : const ContactSyncScreen())));
      await tester.ensureVisible(find.text('Upload & find friends'));
      await tester.tap(find.text('Upload & find friends'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: Text('Left')));
      permission.complete(false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
