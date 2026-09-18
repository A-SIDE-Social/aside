import 'dart:io';
import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import '../../core/services/revenuecat_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/models/partner_offer.dart';
import '../../providers/providers.dart';

class PartnerOfferScreen extends ConsumerStatefulWidget {
  const PartnerOfferScreen({super.key});
  @override
  ConsumerState<PartnerOfferScreen> createState() => _PartnerOfferScreenState();
}

class _PartnerOfferScreenState extends ConsumerState<PartnerOfferScreen>
    with WidgetsBindingObserver {
  final _code = TextEditingController();
  PartnerOffer? _offer;
  String? _error;
  String? _pendingPlan;
  bool _busy = false;
  bool _awaitingReturn = false;
  bool _returnedWhileBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingReturn) {
      if (_busy) {
        _returnedWhileBusy = true;
      } else {
        _awaitingReturn = false;
        _refreshAccess();
      }
    }
  }

  Future<PartnerOffer> _resolve(String code) async {
    final country = (await Purchases.storefront)?.countryCode;
    if (country == null || country.isEmpty) {
      throw StateError('Could not read your store country. Please try again.');
    }
    final json = await ref.read(apiServiceProvider).resolvePartnerOffer(
          code: code,
          platform: Platform.isIOS ? 'ios' : 'android',
          country: country,
        );
    final offer = PartnerOffer.fromJson(json);
    if (!offer.endsAt.isAfter(DateTime.now())) {
      throw StateError('This offer has expired.');
    }
    return offer;
  }

  String _message(Object e) {
    if (e is StateError) return e.message.toString();
    if (e is DioException && [400, 404].contains(e.response?.statusCode)) {
      return 'This code is unavailable or has expired for your store country.';
    }
    return 'Could not check the offer. Please try again.';
  }

  Future<void> _check() async {
    final code = _code.text.trim();
    if (!RegExp(r'^[a-zA-Z0-9]{3,40}$').hasMatch(code)) {
      setState(() {
        _offer = null;
        _error = 'Enter a valid partner code.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _offer = null;
    });
    try {
      final offer = await _resolve(code);
      await ref.read(subscriptionProvider.notifier).loadOfferings();
      if (mounted) setState(() => _offer = offer);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  StoreProduct? _product(PartnerOfferPlan plan) {
    final packages =
        ref.read(subscriptionProvider).offerings?.current?.availablePackages ??
            <Package>[];
    return packages
        .map((p) => p.storeProduct)
        .where((p) =>
            p.identifier == plan.productId ||
            (p.subscriptionOptions?.any((o) =>
                    o.productId == plan.productId && o.id == plan.optionId) ??
                false))
        .firstOrNull;
  }

  Future<void> _redeem(PartnerOfferPlan chosen) async {
    final offer = _offer;
    if (offer == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final userId = ref.read(authProvider).user?.id;
      if (userId == null) {
        throw StateError('Please sign in before redeeming an offer.');
      }
      await RevenueCatService.identify(userId);
      if (!mounted) return;
      // Recheck expiration/config before checkout, so a stale screen cannot bypass closure.
      final current = await _resolve(offer.code);
      if (!mounted) return;
      final plan =
          current.plans.where((p) => p.plan == chosen.plan).firstOrNull;
      if (plan == null ||
          plan.firstYearMicros != chosen.firstYearMicros ||
          plan.renewalMicros != chosen.renewalMicros ||
          plan.currencyCode != chosen.currencyCode ||
          plan.productId != chosen.productId ||
          plan.optionId != chosen.optionId ||
          plan.redemptionUrl != chosen.redemptionUrl) {
        setState(() => _offer = current);
        throw StateError(
            'The offer has changed. Please review its current terms.');
      }
      await ref.read(subscriptionProvider.notifier).loadOfferings();
      if (!mounted) return;
      if (ref.read(authProvider).user?.id != userId) {
        throw StateError('Your account changed. Please check the code again.');
      }
      final product = _product(plan);
      if (product == null) {
        throw StateError('This plan is unavailable in your store.');
      }
      if (Platform.isIOS) {
        if (!plan.matchesAppleProduct(product)) {
          throw StateError(
              'This offer’s store price could not be verified. Please try again later.');
        }
        _pendingPlan = plan.plan;
        _awaitingReturn = true;
        _returnedWhileBusy = false;
        final opened = await launchUrl(plan.redemptionUrl!,
            mode: LaunchMode.externalApplication);
        if (!opened) {
          _awaitingReturn = false;
          throw StateError('Could not open App Store redemption.');
        }
      } else {
        final option = plan.androidOption(product.subscriptionOptions ?? []);
        if (option == null) {
          throw StateError(
              'This offer is not available for your store account. You have not been charged.');
        }
        final success = await ref
            .read(subscriptionProvider.notifier)
            .purchasePartnerOption(option, plan.plan);
        if (!mounted) return;
        if (success) {
          _success();
        } else {
          setState(() => _error = ref.read(subscriptionProvider).error);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      _finishRedemptionAttempt();
    }
  }

  void _finishRedemptionAttempt() {
    if (!mounted) return;
    setState(() => _busy = false);
    if (_awaitingReturn && _returnedWhileBusy) {
      _awaitingReturn = false;
      _returnedWhileBusy = false;
      _refreshAccess();
    }
  }

  Future<void> _refreshAccess() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final success = await ref
        .read(subscriptionProvider.notifier)
        .syncStorePurchases(expectedPlan: _pendingPlan);
    if (!mounted) return;
    if (success) {
      _success();
    } else {
      setState(() {
        _busy = false;
        _error =
            'If you completed redemption, your purchase may still be processing. Try checking again or use Restore Purchases on the Upgrade screen.';
      });
    }
  }

  void _success() {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your Pro subscription is ready.')));
    Navigator.of(context).pop(true);
  }

  Widget _planCard(PartnerOfferPlan plan) {
    final product = _product(plan);
    final option = plan.androidOption(product?.subscriptionOptions ?? []);
    final available = Platform.isIOS
        ? product != null && plan.matchesAppleProduct(product)
        : option != null;
    final firstPrice =
        option?.pricingPhases.first.price.formatted ?? plan.firstYearPrice;
    final renewalPrice = option?.pricingPhases.last.price.formatted ??
        product?.priceString ??
        plan.renewalPrice;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(plan.title,
                      style: Theme.of(context).textTheme.titleMedium),
                  if (plan.plan == 'pro_family') const Text('Up to 6 accounts'),
                  const SizedBox(height: 8),
                  if (available) ...[
                    Text(
                        '$firstPrice for the first year, then $renewalPrice/year.'),
                    const Text(
                        'Renews automatically until canceled in your app store. Any applicable taxes are shown at checkout.'),
                  ] else
                    const Text(
                        'This offer is unavailable for your store account right now. Check your eligibility or try again later.'),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed:
                          _busy || !available ? null : () => _redeem(plan),
                      child: Text(Platform.isIOS
                          ? 'Redeem in App Store'
                          : 'Continue for $firstPrice')),
                ])));
  }

  @override
  Widget build(BuildContext context) {
    final offer = _offer;
    return Scaffold(
      appBar: AppBar(title: const Text('Partner offer')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Have a partner code?',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          const Text(
              'Enter the code your newsletter or community shared. Offers are for new Pro subscribers; your app store checks eligibility.'),
          const SizedBox(height: 20),
          TextField(
              controller: _code,
              enabled: !_busy,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Partner code'),
              onChanged: (_) => setState(() {
                    _offer = null;
                    _error = null;
                  }),
              onSubmitted: (_) => _busy ? null : _check()),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: _busy ? null : _check,
              child: const Text('Check offer')),
          if (_busy)
            const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator())),
          if (offer != null) ...[
            const SizedBox(height: 24),
            Text(offer.name, style: Theme.of(context).textTheme.titleLarge),
            Text(
                'Redeem before ${DateFormat.yMMMd().add_jm().format(offer.endsAt.toLocal())} (your local time).'),
            ...offer.plans.map(_planCard),
          ],
          if (_pendingPlan != null)
            TextButton(
                onPressed: _busy ? null : _refreshAccess,
                child: const Text('Check my redeemed purchase')),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 16),
          const Text(
              'A subscription is optional. Free accounts include the most recent 30 days of feed and message history.'),
        ]),
      ),
    );
  }
}
