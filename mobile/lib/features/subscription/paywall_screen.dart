import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../../core/config/app_colors.dart';
import '../../core/config/env.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  bool _yearly = true;
  bool _family = false;

  @override
  void initState() {
    super.initState();
    ref.read(subscriptionProvider.notifier).loadOfferings();
  }

  Package? _getSelectedPackage(Offerings? offerings) {
    final offering = offerings?.current;
    if (offering == null) return null;

    if (_family) {
      final id = _yearly ? 'family_annual' : 'family_monthly';
      return offering.availablePackages
          .where((p) => p.identifier == id)
          .firstOrNull;
    } else {
      final type = _yearly ? PackageType.annual : PackageType.monthly;
      return offering.availablePackages
          .where((p) => p.packageType == type)
          .firstOrNull;
    }
  }

  Future<void> _purchase() async {
    final sub = ref.read(subscriptionProvider);
    final package = _getSelectedPackage(sub.offerings);
    if (package == null) return;

    final success =
        await ref.read(subscriptionProvider.notifier).purchase(package);
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Welcome to Pro!')),
      );
      context.pop();
    }
  }

  Future<void> _restore() async {
    await ref.read(subscriptionProvider.notifier).restorePurchases();
    if (!mounted) return;

    final status = ref.read(subscriptionProvider).subscriptionStatus;
    if (status == 'active' || status == 'trial') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Purchases restored!')),
      );
      context.pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active subscription found.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final sub = ref.watch(subscriptionProvider);
    final package = _getSelectedPackage(sub.offerings);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.pop(),
        ),
        title: const Text('Upgrade'),
      ),
      body: sub.isLoading
          ? const LoadingIndicator()
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Hero section
                  Icon(
                    Icons.all_inclusive_rounded,
                    size: 56,
                    color: colors.accent,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Unlock your full history',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Free accounts can only see the last 7 days of posts and messages. '
                    'Upgrade to keep everything.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),

                  // Billing period toggle
                  SegmentedButton<bool>(
                    selected: {_yearly},
                    onSelectionChanged: (v) =>
                        setState(() => _yearly = v.first),
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      shape: WidgetStateProperty.all(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      side: WidgetStateProperty.all(
                        BorderSide(color: colors.border, width: 0.5),
                      ),
                    ),
                    segments: const [
                      ButtonSegment(value: false, label: Text('Monthly')),
                      ButtonSegment(value: true, label: Text('Yearly')),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Plan cards
                  _PlanCard(
                    title: 'Pro',
                    subtitle: 'For you',
                    price: _getPriceString(sub.offerings, false),
                    period: _yearly ? '/year' : '/month',
                    savings: _yearly ? 'Save ~17%' : null,
                    features: const [
                      'Unlimited post history',
                      'Unlimited message history',
                    ],
                    selected: !_family,
                    onTap: () => setState(() => _family = false),
                  ),
                  const SizedBox(height: 12),
                  _PlanCard(
                    title: 'Pro Family',
                    subtitle: 'Up to 6 people',
                    price: _getPriceString(sub.offerings, true),
                    period: _yearly ? '/year' : '/month',
                    savings: _yearly ? 'Save ~17%' : null,
                    features: const [
                      'Everything in Pro',
                      'Share with up to 5 family members',
                      'Each member gets unlimited history',
                    ],
                    selected: _family,
                    onTap: () => setState(() => _family = true),
                  ),
                  const SizedBox(height: 24),

                  // Subscribe button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: package != null ? _purchase : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        package != null
                            ? 'Subscribe for ${package.storeProduct.priceString}'
                            : 'Loading...',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  if (sub.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      sub.error!,
                      style: TextStyle(color: AppColors.error, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Restore + legal links
                  TextButton(
                    onPressed: _restore,
                    child: Text(
                      'Restore Purchases',
                      style: TextStyle(color: colors.textTertiary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _LegalLink(
                        text: 'Terms of Service',
                        url: '${Env.appBaseUrl}/terms',
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          '·',
                          style: TextStyle(color: colors.textTertiary),
                        ),
                      ),
                      _LegalLink(
                        text: 'Privacy Policy',
                        url: '${Env.appBaseUrl}/privacy',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Payment will be charged to your Apple ID account at confirmation of purchase. '
                    'Subscription automatically renews unless canceled at least 24 hours before the end of the current period.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textTertiary,
                      fontSize: 11,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
    );
  }

  String _getPriceString(Offerings? offerings, bool isFamily) {
    final offering = offerings?.current;
    if (offering == null) return '...';

    Package? pkg;
    if (isFamily) {
      final id = _yearly ? 'family_annual' : 'family_monthly';
      pkg = offering.availablePackages
          .where((p) => p.identifier == id)
          .firstOrNull;
    } else {
      final type = _yearly ? PackageType.annual : PackageType.monthly;
      pkg = offering.availablePackages
          .where((p) => p.packageType == type)
          .firstOrNull;
    }

    return pkg?.storeProduct.priceString ?? '...';
  }
}

class _PlanCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String price;
  final String period;
  final String? savings;
  final List<String> features;
  final bool selected;
  final VoidCallback onTap;

  const _PlanCard({
    required this.title,
    required this.subtitle,
    required this.price,
    required this.period,
    required this.features,
    required this.selected,
    required this.onTap,
    this.savings,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? colors.accent : colors.border,
            width: selected ? 2 : 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      price,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      period,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (savings != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  savings!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.success,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            ...features.map(
              (f) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.check_rounded,
                        size: 16, color: colors.textSecondary),
                    const SizedBox(width: 8),
                    Text(
                      f,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegalLink extends StatelessWidget {
  final String text;
  final String url;

  const _LegalLink({required this.text, required this.url});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: () => InAppBrowser.open(context, url, title: text),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: colors.textTertiary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}
