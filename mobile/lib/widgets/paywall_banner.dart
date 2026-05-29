import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_colors.dart';

/// Inline "older content hidden" marker shown at the top of a
/// message list or the end of the feed when Free users hit the
/// 30-day history boundary.
///
/// Transparent background (no card), so it blends into whatever list
/// it sits in instead of reading as a second surface layered on the
/// background. Keeps the lock glyph + short explanation + a link-
/// styled Upgrade tap target. Reads as "the list continues above
/// this, but you need Pro to see it" rather than a heavy CTA.
class PaywallBanner extends StatelessWidget {
  const PaywallBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 18,
            color: colors.textTertiary,
          ),
          const SizedBox(height: 10),
          Text(
            'Older content is hidden',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            'Free accounts can see the last 30 days.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => context.push('/upgrade'),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              child: Text(
                'Upgrade to Pro',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
