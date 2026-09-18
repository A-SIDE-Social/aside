import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import '../models/partner_offer_test.dart' show option;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:aside/providers/providers.dart';
import '../../helpers/mocks.dart';

class QuietAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('canceling native checkout leaves access unchanged and no error',
      () async {
    const channel = MethodChannel('purchases_flutter');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (_) async => throw PlatformException(code: '1'));
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final api = MockApiService();
    final container = ProviderContainer(
        overrides: [apiServiceProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    final result = await container
        .read(subscriptionProvider.notifier)
        .purchasePartnerOption(option(), 'pro_individual');
    expect(result, isFalse);
    expect(container.read(subscriptionProvider).error, isNull);
    expect(container.read(subscriptionProvider).subscriptionPlan, 'free');
    expect(container.read(subscriptionProvider).isLoading, isFalse);
    verifyNever(() => api.getSubscriptionStatus());
  });

  test('waits for delayed backend entitlement and the requested plan', () {
    fakeAsync((time) {
      final api = MockApiService();
      var calls = 0;
      when(() => api.getSubscriptionStatus()).thenAnswer((_) async {
        calls++;
        return calls < 3
            ? {'plan': 'pro_individual', 'status': 'active'}
            : {'plan': 'pro_family', 'status': 'active'};
      });
      final container = ProviderContainer(overrides: [
        apiServiceProvider.overrideWithValue(api),
        authProvider.overrideWith(QuietAuth.new)
      ]);
      bool? result;
      container
          .read(subscriptionProvider.notifier)
          .waitForStoreUpdate(expectedPlan: 'pro_family')
          .then((v) => result = v);
      time.flushMicrotasks();
      expect(result, isNull);
      time.elapse(const Duration(seconds: 3));
      expect(result, isTrue);
      expect(calls, 3);
      container.dispose();
    });
  });
  test('does not report purchase success when webhook is still pending', () {
    fakeAsync((time) {
      final api = MockApiService();
      when(() => api.getSubscriptionStatus())
          .thenAnswer((_) async => {'plan': 'free', 'status': 'free'});
      final container = ProviderContainer(overrides: [
        apiServiceProvider.overrideWithValue(api),
        authProvider.overrideWith(QuietAuth.new)
      ]);
      bool? result;
      container
          .read(subscriptionProvider.notifier)
          .waitForStoreUpdate(expectedPlan: 'pro_individual')
          .then((v) => result = v);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 16));
      expect(result, isFalse);
      expect(container.read(subscriptionProvider).error,
          contains('still being checked'));
      verify(() => api.getSubscriptionStatus()).called(6);
      container.dispose();
    });
  });
}
