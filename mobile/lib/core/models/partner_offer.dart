import 'package:intl/intl.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

class PartnerOffer {
  final String code;
  final String name;
  final DateTime endsAt;
  final List<PartnerOfferPlan> plans;
  PartnerOffer.fromJson(Map<String, dynamic> json)
      : code = json['code'] as String,
        name = json['name'] as String,
        endsAt = DateTime.parse(json['endsAt'] as String),
        plans = (json['plans'] as List)
            .map((p) => PartnerOfferPlan.fromJson(Map<String, dynamic>.from(p)))
            .toList();
}

class PartnerOfferPlan {
  final String plan;
  final String productId;
  final String currencyCode;
  final int firstYearMicros;
  final int renewalMicros;
  final String? optionId;
  final Uri? redemptionUrl;
  PartnerOfferPlan.fromJson(Map<String, dynamic> json)
      : plan = json['plan'] as String,
        productId = json['productId'] as String,
        currencyCode = json['currencyCode'] as String,
        firstYearMicros = json['firstYearMicros'] as int,
        renewalMicros = json['renewalMicros'] as int,
        optionId = json['optionId'] as String?,
        redemptionUrl = json['redemptionUrl'] == null
            ? null
            : Uri.parse(json['redemptionUrl'] as String);

  String get title => plan == 'pro_family' ? 'Pro Family' : 'Pro Individual';
  String get firstYearPrice => NumberFormat.currency(name: currencyCode)
      .format(firstYearMicros / 1000000);
  String get renewalPrice =>
      NumberFormat.currency(name: currencyCode).format(renewalMicros / 1000000);
  bool get hasSafeRedemptionUrl =>
      redemptionUrl?.scheme == 'https' &&
      redemptionUrl?.host == 'apps.apple.com' &&
      redemptionUrl?.path == '/redeem' &&
      redemptionUrl?.userInfo == '' &&
      !redemptionUrl!.hasPort;

  bool matchesAppleProduct(StoreProduct product) =>
      product.identifier == productId &&
      product.currencyCode == currencyCode &&
      isAnnualPeriod(product.subscriptionPeriod) &&
      (product.price * 1000000).round() == renewalMicros &&
      hasSafeRedemptionUrl;

  SubscriptionOption? androidOption(Iterable<SubscriptionOption> options) {
    for (final o in options) {
      if (o.id != optionId ||
          o.productId != productId ||
          o.isBasePlan ||
          o.isPrepaid ||
          o.pricingPhases.length != 2) {
        continue;
      }
      final first = o.pricingPhases[0];
      final renewal = o.pricingPhases[1];
      final onePayment = first.recurrenceMode == RecurrenceMode.nonRecurring ||
          (first.recurrenceMode == RecurrenceMode.finiteRecurring &&
              first.billingCycleCount == 1);
      if (onePayment &&
          isAnnualPeriod(first.billingPeriod?.iso8601) &&
          isAnnualPeriod(renewal.billingPeriod?.iso8601) &&
          renewal.recurrenceMode == RecurrenceMode.infiniteRecurring &&
          first.price.currencyCode == currencyCode &&
          renewal.price.currencyCode == currencyCode &&
          first.price.amountMicros == firstYearMicros &&
          renewal.price.amountMicros == renewalMicros &&
          firstYearMicros > 0 &&
          firstYearMicros < renewalMicros) {
        return o;
      }
    }
    return null;
  }
}

bool isAnnualPeriod(String? value) => value == 'P1Y' || value == 'P12M';

/// Ordinary checkout must not accidentally choose a reserved partner discount.
SubscriptionOption? annualBasePlan(Iterable<SubscriptionOption> options) {
  return options
      .where((o) =>
          o.isBasePlan &&
          !o.isPrepaid &&
          isAnnualPeriod(o.billingPeriod?.iso8601) &&
          o.pricingPhases.length == 1 &&
          o.pricingPhases.single.recurrenceMode ==
              RecurrenceMode.infiniteRecurring)
      .firstOrNull;
}
