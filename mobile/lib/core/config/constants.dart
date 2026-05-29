/// Central source of truth for all app limits.
class AppLimits {
  AppLimits._();

  // ── Hard limits (same for all users) ────────────────────────
  static const int maxPhotosPerPost = 10;
  static const int maxGroups = 10;
  static const int maxVideoStorySeconds = 30;
  static const int maxVideoPostSeconds = 15;
  static const int maxInvites = 25;
  static const int maxBioLength = 160;
  // 2,200 matches Instagram. Generous enough that voice-dictated captions
  // and the occasional long-form post fit, while still bounded so the feed
  // doesn't degenerate into walls of text. Keep in sync with
  // src/constants.ts on the backend.
  static const int maxCaptionLength = 2200;
  static const int maxTextPostLength = 2200;
  static const int maxCommentLength = 1000;
  static const int maxGroupNameLength = 30;
  static const int storyExpirationHours = 24;

  // ── Plan-gated (only feed history) ──────────────────────────
  static const int freeFeedHistoryDays = 30;

  /// Returns the feed history limit in days, or null for unlimited.
  static int? feedHistoryDays(String? subscriptionStatus) {
    final s = subscriptionStatus ?? 'expired';
    return (s == 'trial' || s == 'active') ? null : freeFeedHistoryDays;
  }

  /// Returns the message history limit in days, or null for unlimited.
  static int? messageHistoryDays(String? subscriptionStatus) =>
      feedHistoryDays(subscriptionStatus);

  /// Whether the user has a paid/trial subscription.
  static bool isPaid(String? subscriptionStatus) {
    final s = subscriptionStatus ?? 'expired';
    return s == 'trial' || s == 'active';
  }

  /// Human-readable plan label for display.
  static String planLabel(String? subscriptionPlan) {
    return switch (subscriptionPlan) {
      'pro_individual' => 'Pro',
      'pro_family' => 'Pro Family',
      _ => 'Free',
    };
  }
}
