import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:aside/core/models/partner_offer.dart';

const year = Period(PeriodUnit.year, 1, 'P1Y');
const month = Period(PeriodUnit.month, 1, 'P1M');
PricingPhase phase(int amount,
        {Period period = year,
        String currency = 'USD',
        RecurrenceMode recurrence = RecurrenceMode.infiniteRecurring,
        int? cycles}) =>
    PricingPhase(period, recurrence, cycles,
        Price('\$${amount / 1000000}', amount, currency), null);
SubscriptionOption option(
        {String id = 'annual:partner-year',
        String product = 'individual',
        List<PricingPhase>? phases,
        bool base = false}) =>
    SubscriptionOption(
        id,
        '$product:annual',
        product,
        phases ??
            [
              phase(15000000,
                  recurrence: RecurrenceMode.finiteRecurring, cycles: 1),
              phase(20000000),
            ],
        const ['rc-ignore-offer'],
        base,
        year,
        false,
        null,
        null,
        null,
        null,
        null);
PartnerOfferPlan plan(
        {String url =
            'https://apps.apple.com/redeem?ctx=offercodes&id=123&code=EXAMPLE'}) =>
    PartnerOfferPlan.fromJson({
      'plan': 'pro_individual',
      'productId': 'individual',
      'currencyCode': 'USD',
      'firstYearMicros': 15000000,
      'renewalMicros': 20000000,
      'optionId': 'annual:partner-year',
      'redemptionUrl': url
    });

void main() {
  test('selects the explicit matching Android offer, not a cheaper trial', () {
    final expected = option();
    expect(plan().androidOption([option(id: 'annual:trial'), expected]),
        same(expected));
  });
  test(
      'fails closed for missing eligibility, changed prices, currency or duration',
      () {
    final invalid = [
      option(id: 'annual:other'),
      option(product: 'family'),
      option(base: true),
      option(phases: [phase(20000000)]),
      option(phases: [
        phase(16000000, recurrence: RecurrenceMode.nonRecurring),
        phase(20000000)
      ]),
      option(phases: [
        phase(15000000, period: month, recurrence: RecurrenceMode.nonRecurring),
        phase(20000000)
      ]),
      option(phases: [
        phase(15000000,
            currency: 'EUR', recurrence: RecurrenceMode.nonRecurring),
        phase(20000000)
      ]),
      option(phases: [
        phase(15000000, recurrence: RecurrenceMode.finiteRecurring, cycles: 2),
        phase(20000000)
      ]),
      option(phases: [
        phase(15000000, recurrence: RecurrenceMode.nonRecurring),
        phase(21000000)
      ]),
    ];
    expect(plan().androidOption([]), isNull);
    for (final candidate in invalid) {
      expect(plan().androidOption([candidate]), isNull,
          reason: candidate.toString());
    }
  });
  test('ordinary annual checkout never chooses a partner offer', () {
    final base = option(id: 'annual', base: true, phases: [phase(20000000)]);
    expect(annualBasePlan([option(), base]), same(base));
    expect(annualBasePlan([option()]), isNull);
  });
  test('iOS validates regular product price, period and redemption origin', () {
    const product = StoreProduct(
        'individual', 'description', 'Pro', 20, '\$20.00', 'USD',
        subscriptionPeriod: 'P1Y');
    expect(plan().matchesAppleProduct(product), isTrue);
    for (final url in [
      'http://apps.apple.com/redeem',
      'https://apps.apple.com.evil.test/redeem',
      'https://evil.test/redeem',
      'https://apps.apple.com:8443/redeem',
      'https://apps.apple.com/other'
    ]) {
      expect(plan(url: url).matchesAppleProduct(product), isFalse);
    }
    expect(
        plan().matchesAppleProduct(const StoreProduct(
            'individual', 'desc', 'Pro', 21, '\$21', 'USD',
            subscriptionPeriod: 'P1Y')),
        isFalse);
    expect(
        plan().matchesAppleProduct(const StoreProduct(
            'individual', 'desc', 'Pro', 20, '\$20', 'USD',
            subscriptionPeriod: 'P1M')),
        isFalse);
  });
}
