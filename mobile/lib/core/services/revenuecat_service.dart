import 'dart:io';
import 'package:flutter/services.dart';
import '../models/partner_offer.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/env.dart';

class SubscriptionsUnavailableException implements Exception {
  const SubscriptionsUnavailableException();

  @override
  String toString() => RevenueCatService.unavailableMessage;
}

class RevenueCatService {
  static const unavailableMessage =
      'Subscriptions are temporarily unavailable. Please try again later.';
  static bool _initialized = false;

  /// Initialize RevenueCat SDK. Call once before runApp().
  static Future<void> initialize() async {
    final apiKey = Env.revenueCatApiKey.trim();
    if (apiKey.isEmpty) return; // Skip in development if no key configured

    final config = PurchasesConfiguration(apiKey);
    try {
      await Purchases.configure(config);
      _initialized = true;
    } on PlatformException {
      // Subscription setup must not prevent access to the rest of the app.
      _initialized = false;
    }
  }

  static Future<void> _requireConfigured() async {
    // This query is safe before initialization. Other native SDK calls can
    // terminate the process rather than return a catchable platform error.
    if (!await Purchases.isConfigured) {
      throw const SubscriptionsUnavailableException();
    }
  }

  /// Identify user after login. Links RevenueCat customer to our user ID.
  static Future<void> identify(String userId) async {
    if (!_initialized) return;
    await _requireConfigured();
    await Purchases.logIn(userId);
  }

  /// Log out user on sign-out.
  static Future<void> logOut() async {
    if (!_initialized) return;
    await _requireConfigured();
    await Purchases.logOut();
  }

  /// Fetch available subscription offerings.
  static Future<Offerings> getOfferings() async {
    await _requireConfigured();
    return await Purchases.getOfferings();
  }

  /// Purchase a package (triggers platform payment sheet).
  static Future<PurchaseResult> purchasePackage(Package package) async {
    await _requireConfigured();
    if (Platform.isAndroid) {
      final option =
          annualBasePlan(package.storeProduct.subscriptionOptions ?? []);
      if (option == null) {
        throw StateError('The annual plan is unavailable. Please try again.');
      }
      return await purchaseOption(option);
    }
    return await Purchases.purchase(PurchaseParams.package(package));
  }

  static Future<PurchaseResult> purchaseOption(
      SubscriptionOption option) async {
    await _requireConfigured();
    return Purchases.purchase(PurchaseParams.subscriptionOption(option));
  }

  static Future<void> syncPurchases() async {
    await _requireConfigured();
    await Purchases.syncPurchases();
  }

  /// Get current customer info (entitlements, subscription status).
  static Future<CustomerInfo> getCustomerInfo() async {
    await _requireConfigured();
    return await Purchases.getCustomerInfo();
  }

  /// Restore purchases (for users who reinstalled or switched devices).
  static Future<CustomerInfo> restorePurchases() async {
    await _requireConfigured();
    return await Purchases.restorePurchases();
  }

  /// Open the platform subscription management UI via managementURL.
  static Future<void> showManageSubscriptions() async {
    if (!_initialized) return;
    final info = await getCustomerInfo();
    final url = info.managementURL;
    if (url != null) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  /// Check if the user has the 'pro' entitlement.
  static Future<bool> hasProEntitlement() async {
    if (!_initialized) return false;
    final info = await getCustomerInfo();
    return info.entitlements.active.containsKey('pro');
  }
}
