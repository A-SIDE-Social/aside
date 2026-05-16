/// Build-time environment configuration.
///
/// Each value is overridable via `--dart-define KEY=value` at build
/// time. The defaults below target a local-development setup; production
/// builds set `--dart-define API_BASE_URL=https://api.your-domain.tld`,
/// `REVENUECAT_API_KEY=...`, etc.
class Env {
  static String get apiBaseUrl => const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://localhost:3000',
      );

  static String get wsBaseUrl => const String.fromEnvironment(
        'WS_BASE_URL',
        defaultValue: 'http://localhost:3000',
      );

  static String get appBaseUrl => const String.fromEnvironment(
        'APP_BASE_URL',
        defaultValue: 'http://localhost:3000',
      );

  static List<String> get appLinkHosts => _csv(
        const String.fromEnvironment(
          'APP_LINK_HOSTS',
          defaultValue: 'localhost',
        ),
      );

  static String get appName => const String.fromEnvironment(
        'APP_NAME',
        defaultValue: 'A/SIDE',
      );

  static String get termsUrl => const String.fromEnvironment(
        'TERMS_URL',
        defaultValue: 'http://localhost:3000/terms',
      );

  static String get privacyUrl => const String.fromEnvironment(
        'PRIVACY_URL',
        defaultValue: 'http://localhost:3000/privacy',
      );

  static String get supportEmail => const String.fromEnvironment(
        'SUPPORT_EMAIL',
        defaultValue: 'support@example.com',
      );

  /// RevenueCat public API key. Required for in-app subscriptions to
  /// work; the app runs free-tier-only without it. Get one at
  /// <https://www.revenuecat.com/>.
  static String get revenueCatApiKey => const String.fromEnvironment(
        'REVENUECAT_API_KEY',
        defaultValue: '',
      );

  static String inviteUrl(String code) => '$appBaseUrl/join/$code';

  static List<String> _csv(String value) => value
      .split(',')
      .map((host) => host.trim().toLowerCase())
      .where((host) => host.isNotEmpty)
      .toList(growable: false);
}
