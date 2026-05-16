import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aside/providers/usage_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('UsageNotifier', () {
    test('initial state is 0', () {
      fakeAsync((async) {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer();
        final notifier = container.read(usageProvider.notifier);
        expect(container.read(usageProvider), 0);
        notifier.pauseSession(); // stop timer before container dispose
        container.dispose();
      });
    });

    test('startSession increments state every second', () {
      fakeAsync((async) {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer();
        container.read(usageProvider.notifier);

        async.elapse(const Duration(seconds: 3));
        expect(container.read(usageProvider), 3);

        container.dispose();
      });
    });

    test('pauseSession stops the timer', () {
      fakeAsync((async) {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer();
        final notifier = container.read(usageProvider.notifier);

        async.elapse(const Duration(seconds: 2));
        notifier.pauseSession();

        async.elapse(const Duration(seconds: 5));
        expect(
            container.read(usageProvider), 2); // didn't increment after pause

        container.dispose();
      });
    });

    test('resume after pause continues incrementing', () {
      fakeAsync((async) {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer();
        final notifier = container.read(usageProvider.notifier);

        async.elapse(const Duration(seconds: 2));
        notifier.pauseSession();

        async.elapse(const Duration(seconds: 3));
        notifier.startSession();

        async.elapse(const Duration(seconds: 2));
        expect(container.read(usageProvider), 4); // 2 + 2

        container.dispose();
      });
    });
  });

  group('formatUsageTime', () {
    test('formats seconds under 60', () {
      expect(formatUsageTime(0), '0s');
      expect(formatUsageTime(45), '45s');
    });

    test('formats minutes under 60', () {
      expect(formatUsageTime(60), '1m');
      expect(formatUsageTime(90), '1m');
      expect(formatUsageTime(3599), '59m');
    });

    test('formats exact hours', () {
      expect(formatUsageTime(3600), '1h');
      expect(formatUsageTime(7200), '2h');
    });

    test('formats hours and minutes', () {
      expect(formatUsageTime(3660), '1h 1m');
      expect(formatUsageTime(5400), '1h 30m');
    });
  });
}
