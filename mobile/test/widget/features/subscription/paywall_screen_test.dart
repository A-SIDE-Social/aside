import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aside/core/services/revenuecat_service.dart';
import 'package:aside/features/subscription/paywall_screen.dart';

Map<String, dynamic> offerings() {
  final package = {
    'identifier': r'$rc_annual',
    'packageType': 'ANNUAL',
    'product': {
      'identifier': 'aside_pro_yearly',
      'description': 'Annual',
      'title': 'Pro',
      'price': 20.0,
      'priceString': r'$20.00',
      'currencyCode': 'USD',
      'subscriptionPeriod': 'P1Y',
    },
    'presentedOfferingContext': {'offeringIdentifier': 'default'},
  };
  final offering = {
    'identifier': 'default',
    'serverDescription': 'Default',
    'metadata': {},
    'availablePackages': [package],
    'annual': package,
  };
  return {
    'all': {'default': offering},
    'current': offering
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('purchases_flutter');

  testWidgets('unconfigured subscriptions show a safe retry state',
      (tester) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isConfigured') return false;
      fail('Unsafe native method invoked: ${call.method}');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: PaywallScreen())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(RevenueCatService.unavailableMessage), findsOneWidget);
    expect(find.text('Plans unavailable'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    final retry = find.text('Try again');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(calls, ['isConfigured', 'isConfigured']);
  });

  testWidgets('offerings can recover after a temporary store error',
      (tester) async {
    var requests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isConfigured') return true;
      if (call.method == 'getOfferings') {
        requests++;
        if (requests == 1) throw PlatformException(code: '10');
        return offerings();
      }
      fail('Unexpected native method: ${call.method}');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: PaywallScreen())));
    await tester.pumpAndSettle();
    final retry = find.text('Try again');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(requests, 2);
    expect(find.text(RevenueCatService.unavailableMessage), findsNothing);
    expect(find.text(r'Subscribe for $20.00'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
}
