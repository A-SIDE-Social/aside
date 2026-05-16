import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aside/providers/theme_provider.dart';

void main() {
  group('ThemeModeNotifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('initial state is ThemeMode.system', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(themeModeProvider), ThemeMode.system);
    });

    test('loads persisted theme from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Touch the provider to instantiate the notifier + start the load.
      container.read(themeModeProvider);
      // Wait for async _load() to complete.
      await Future.delayed(Duration.zero);
      expect(container.read(themeModeProvider), ThemeMode.dark);
    });

    test('setThemeMode updates state and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(themeModeProvider.notifier);
      await notifier.setThemeMode(ThemeMode.light);

      expect(container.read(themeModeProvider), ThemeMode.light);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode'), 'light');
    });

    test('cycle goes system -> light -> dark -> system', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(themeModeProvider.notifier);

      expect(container.read(themeModeProvider), ThemeMode.system);

      await notifier.cycle();
      expect(container.read(themeModeProvider), ThemeMode.light);

      await notifier.cycle();
      expect(container.read(themeModeProvider), ThemeMode.dark);

      await notifier.cycle();
      expect(container.read(themeModeProvider), ThemeMode.system);
    });
  });
}
