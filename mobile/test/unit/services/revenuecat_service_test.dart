import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:aside/core/services/revenuecat_service.dart';
import '../models/partner_offer_test.dart' show option;

const package = Package(
    r'$rc_annual',
    PackageType.annual,
    StoreProduct('aside_pro_yearly', 'Annual', 'Pro', 20, r'$20.00', 'USD'),
    PresentedOfferingContext('default', null, null));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('purchases_flutter');
  final operations = <String, Future<dynamic> Function()>{
    'offerings': RevenueCatService.getOfferings,
    'package purchase': () => RevenueCatService.purchasePackage(package),
    'partner purchase': () => RevenueCatService.purchaseOption(option()),
    'purchase synchronization': RevenueCatService.syncPurchases,
    'customer info': RevenueCatService.getCustomerInfo,
    'restore': RevenueCatService.restorePurchases,
  };

  for (final operation in operations.entries) {
    test('${operation.key} never reaches an unconfigured native SDK', () async {
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
      await expectLater(
          operation.value(), throwsA(isA<SubscriptionsUnavailableException>()));
      expect(calls, ['isConfigured']);
    });
  }

  test('configured SDK still receives synchronization requests', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'isConfigured' ? true : null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await RevenueCatService.syncPurchases();
    expect(calls, ['isConfigured', 'syncPurchases']);
  });
}
