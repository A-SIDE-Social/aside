# Partner subscription offers

Partner codes select native subscription offers on existing annual products. They do not grant Pro, change entitlements, or collect payment. RevenueCat's existing webhook and subscription API remain authoritative. No database migration or new SDK is required.

## Configuration

`PARTNER_OFFERS_JSON` is a JSON array loaded at startup, default `[]`. Configure only verified store prices; all offers stay unavailable until explicitly enabled. This example is deliberately inactive and has placeholder dates and store identifiers:

```json
[{"code":"EXAMPLE","name":"Example readers","active":false,"startsAt":"2099-01-01T00:00:00Z","endsAt":"2099-04-01T00:00:00Z","plans":{"pro_individual":{"iosProductId":"aside_pro_yearly","androidProductId":"aside_pro_yearly","androidBasePlanId":"annual","androidOfferId":"partner-year","appleCode":"EXAMPLEIND","prices":{"USA":{"currencyCode":"USD","firstYearMicros":15000000,"renewalMicros":20000000}}}}}]
```

Add `pro_family` with the Family product and its own Apple code when applicable. Prices are integer micros (one currency unit = 1,000,000). Each country entry uses a store country code; US and USA requests normalize to USA. For other markets, use the country identifiers actually returned by the two SDKs (add both aliases when different). Unsupported markets fail closed. Set `APPLE_APP_ID` to the hosted app's numeric Apple ID.

`startsAt` is inclusive; `endsAt` is exclusive. Use explicit UTC timestamps aligned with native-store expiration. Disabled, expired, future and unknown codes return the same unavailable response. Invalid configuration fails startup rather than guessing. Changing configuration requires a backend restart.

## API and app

`POST /v1/partner-offers/resolve` accepts `{ "code": "EXAMPLE", "platform": "ios", "country": "USA" }`. This public, rate-limited endpoint returns `{ "offer": ... }` with public display terms and native redemption information. Responses use `Cache-Control: no-store`; request bodies contain no user identifiers. Codes are shareable marketing identifiers, not secrets or proof of newsletter membership. Do not log request bodies at the proxy.

Settings → Upgrade to Pro → Have a partner code? reads the store country and resolves the campaign. Before checkout the app rechecks campaign terms and matches the native product. Android shows the matching native option's formatted prices and purchases that exact option; missing eligibility, price/currency/duration mismatch or a missing option cannot fall back to a full-price purchase. Ordinary Android checkout explicitly selects the annual base plan, even if an offer is accidentally exposed as the default.

On iOS, the app verifies the normal annual product price and opens Apple's offer-code redemption URL. The ordinary product API does not expose the code's discounted price: the configured first-year amount MUST match the offer set up in App Store Connect, and Apple's redemption sheet is the final confirmation. Returning to the app syncs purchases and checks the backend. An explicit check button and Restore Purchases cover delayed updates. A successful URL launch is never treated as a completed purchase.

## Store setup and release

1. On each existing Apple annual subscription, create an Offer Code offer: new subscribers only, no introductory-offer stacking, one year paid up front, the chosen territories/prices. Create distinct custom codes for Individual and Family. Custom codes cannot be shared across products.
2. On each Google annual base plan, create a subscription offer for customers who have never had any subscription. Add one discounted annual phase followed by normal annual renewal. Tag it `rc-ignore-offer`; do not use Play promo codes, which implement free trials rather than this paid discount.
3. Preserve existing RevenueCat products, packages and `pro` entitlement mapping. Check that each Google eligible `SubscriptionOption.id` is `basePlanId:offerId`. No additional package or entitlement is needed.
4. Release the backend with campaigns disabled and release the updated app. The website's optional `/offers` page explains installation and redemption; it does not handle billing.
5. Test in a staging backend/config and store sandbox/internal test tracks. Cover both plans, an eligible new customer, existing subscriber rejection, canceled checkout, expired/disabled/unknown codes, unsupported market, changed native prices, delayed webhook, restore/reinstall, Family access and ordinary full-price checkout. Apple code-discount correctness requires inspection of the native sheet; it is not proven by unit tests.
6. After agreeing publication dates, verify the exact US/local amounts and renewal terms in both consoles, match UTC expiration, then enable the production campaign. To close a campaign, disable configuration AND deactivate its Apple code/Google offer as appropriate. Previously issued direct Apple URLs remain usable until Apple expires/deactivates them; backend disabling alone cannot revoke those links.

Future partners can reuse the same benefit and flow by adding a campaign and Apple custom codes. Google offer IDs may be shared if aggregate reporting is sufficient. Do not claim per-partner attribution from Apple custom codes: offer reference reporting may identify only the reused benefit. This implementation deliberately adds no customer tracking or subscriber-list verification.

## References

- [Apple offer-code setup](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-subscription-offer-codes)
- [Google subscription offers](https://support.google.com/googleplay/android-developer/answer/140504?hl=en)
- [RevenueCat offer selection](https://www.revenuecat.com/docs/subscription-guidance/subscription-offers)
- [RevenueCat iOS offers](https://www.revenuecat.com/docs/subscription-guidance/subscription-offers/ios-subscription-offers)
