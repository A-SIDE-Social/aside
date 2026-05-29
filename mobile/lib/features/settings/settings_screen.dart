import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_colors.dart';
import '../../core/config/constants.dart';
import '../../core/config/env.dart';
import '../../core/services/revenuecat_service.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';
import '../invites/invite_link_card.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final authState = ref.watch(authProvider);
    final user = authState.user;
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          const SizedBox(height: 16),

          // Account header — tap to go to own profile
          if (user != null)
            AppCard(
              onTap: () => context.go('/profile'),
              child: Row(
                children: [
                  Avatar(
                    imageUrl: user.avatarUrl,
                    displayName: user.displayName,
                    size: 48,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      user.displayName,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.textTertiary,
                    size: 20,
                  ),
                ],
              ),
            ),

          const SizedBox(height: 16),

          // Friends — people-side of the social graph. "Friends" sits
          // first because tapping into your existing connections is
          // the more frequent action; the "Find" row sits beneath
          // for when you want to grow the list. Route stays
          // /connections so existing push-notification deep links
          // keep working (deep_link.dart routes inbound_follow +
          // new_mutual here).
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsRow(
                  title: 'Friends',
                  onTap: () => context.push('/connections'),
                  showDivider: true,
                ),
                _SettingsRow(
                  title: 'Find Friends from Contacts',
                  onTap: () => context.push('/contacts'),
                  showDivider: false,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Invite Friends — inline card (no nav row). Personal
          // invite link + Share / QR / Regenerate. Legacy invite
          // codes were removed in 1.3.0, so there's nothing to redeem
          // here either.
          const InviteLinkCard(),

          const SizedBox(height: 16),

          // Plan section
          if (user != null)
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Plan', style: theme.textTheme.labelLarge),
                      _PlanBadge(
                          plan: user.subscriptionPlan,
                          status: user.subscriptionStatus),
                    ],
                  ),
                  if (AppLimits.isPaid(user.subscriptionStatus)) ...[
                    if (user.subscriptionPlan == 'pro_family') ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () => context.push('/family'),
                        child: Text(
                          'Manage family members',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.accent,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () =>
                            RevenueCatService.showManageSubscriptions(),
                        child: const Text('Manage Subscription'),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => context.push('/upgrade'),
                        child: const Text('Upgrade to Pro'),
                      ),
                    ),
                  ],
                ],
              ),
            ),

          const SizedBox(height: 16),

          // Appearance section
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Appearance', style: theme.textTheme.labelLarge),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    selected: {themeMode},
                    onSelectionChanged: (modes) {
                      ref
                          .read(themeModeProvider.notifier)
                          .setThemeMode(modes.first);
                    },
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
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto_outlined, size: 18),
                        label: Text('System'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined, size: 18),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined, size: 18),
                        label: Text('Dark'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Notifications section
          AppCard(
            padding: EdgeInsets.zero,
            child: _SettingsRow(
              title: 'Notifications',
              showDivider: false,
              onTap: () => context.push('/settings/notifications'),
            ),
          ),

          const SizedBox(height: 16),

          // (Build 40: the inline DM privacy notice that used to
          // live here was moved to the marketing site's encryption
          // FAQ — Settings is for managing your account, not
          // re-educating users about the protocol.)

          // Usage row — uses the same _SettingsRow shape as Version
          // so the title/value rhythm matches the rest of the page
          // (bodyLarge title, muted trailing value) instead of being
          // a one-off labelLarge/titleMedium pair.
          AppCard(
            padding: EdgeInsets.zero,
            child: _SettingsRow(
              title: "Today's Usage",
              trailing: Consumer(
                builder: (context, ref, _) {
                  final seconds = ref.watch(usageProvider);
                  return Text(
                    _formatUsage(seconds),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.textTertiary,
                    ),
                  );
                },
              ),
              showChevron: false,
              showDivider: false,
            ),
          ),

          const SizedBox(height: 16),

          // Info & legal
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsRow(
                  title: 'Terms of Service',
                  onTap: () {
                    InAppBrowser.open(
                      context,
                      Env.termsUrl,
                      title: 'Terms of Service',
                    );
                  },
                  showDivider: true,
                ),
                _SettingsRow(
                  title: 'Privacy Policy',
                  onTap: () {
                    InAppBrowser.open(
                      context,
                      Env.privacyUrl,
                      title: 'Privacy Policy',
                    );
                  },
                  showDivider: true,
                ),
                _SettingsRow(
                  title: 'Source Code',
                  onTap: () {
                    InAppBrowser.open(
                      context,
                      Env.sourceCodeUrl,
                      title: 'Source Code',
                    );
                  },
                  showDivider: true,
                ),
                _SettingsRow(
                  title: 'Open Source Licenses',
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: Env.appName,
                  ),
                  showDivider: true,
                ),
                _SettingsRow(
                  title: 'Contact Us',
                  onTap: () {
                    launchUrl(
                      Uri.parse('mailto:${Env.supportEmail}'),
                    );
                  },
                  showDivider: true,
                ),
                _SettingsRow(
                  title: 'Version',
                  trailing: Text(
                    '1.0.0',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                  showChevron: false,
                  showDivider: false,
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Sign out
          AppCard(
            padding: EdgeInsets.zero,
            child: _SettingsRow(
              title: 'Sign Out',
              titleColor: AppColors.error,
              showChevron: false,
              showDivider: false,
              onTap: () => _confirmSignOut(context),
            ),
          ),

          // Dev-only: E2EE Phase 1a FFI spike verification. Removed when
          // the real crypto UI ships in Phase 1b.
          if (kDebugMode) ...[
            const SizedBox(height: 16),
            AppCard(
              padding: EdgeInsets.zero,
              child: _SettingsRow(
                title: 'E2EE spike (debug)',
                showDivider: false,
                onTap: () => context.push('/debug/e2ee'),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Account actions
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsRow(
                  title: 'Deactivate Account',
                  titleColor: AppColors.error,
                  showDivider: true,
                  onTap: () => _openAccountAction(context, 'deactivate', user),
                ),
                _SettingsRow(
                  title: 'Delete Account',
                  titleColor: AppColors.error,
                  showDivider: false,
                  onTap: () => _openAccountAction(context, 'delete', user),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _formatUsage(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    if (rem == 0) return '${hours}h';
    return '${hours}h ${rem}m';
  }

  void _confirmSignOut(BuildContext context) {
    final colors = AppColors.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.border, width: 0.5),
        ),
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              ref.invalidate(feedNotifierProvider);
              await ref.read(authProvider.notifier).signOut();
            },
            child: Text(
              'Sign Out',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }

  void _openAccountAction(BuildContext context, String action, User? user) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final isDeactivate = action == 'deactivate';

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(isDeactivate ? 'Deactivate Account' : 'Delete Account'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isDeactivate
                      ? Icons.pause_circle_outline_rounded
                      : Icons.warning_amber_rounded,
                  size: 48,
                  color: isDeactivate ? colors.textTertiary : AppColors.error,
                ),
                const SizedBox(height: 24),
                Text(
                  isDeactivate
                      ? 'Take a break'
                      : 'Permanently delete your account',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  isDeactivate
                      ? 'Your account will be hidden and your content will no longer be visible to connections. You can reactivate at any time by signing back in.'
                      : 'This will permanently delete your account, posts, messages, and all associated data. This action cannot be undone.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      final subject = Uri.encodeComponent(
                        '${isDeactivate ? 'Deactivate' : 'Delete'} Account Request',
                      );
                      final body = Uri.encodeComponent(
                        'Please ${isDeactivate ? 'deactivate' : 'delete'} my account.\n\nUser ID: ${user?.id ?? 'unknown'}\nName: ${user?.displayName ?? 'unknown'}',
                      );
                      launchUrl(
                        Uri.parse(
                          'mailto:${Env.supportEmail}?subject=$subject&body=$body',
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDeactivate ? null : AppColors.error,
                    ),
                    child: Text(
                      isDeactivate
                          ? 'Request Deactivation'
                          : 'Request Account Deletion',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String title;
  final Color? titleColor;
  final bool showChevron;
  final bool showDivider;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _SettingsRow({
    required this.title,
    this.titleColor,
    this.showChevron = true,
    this.showDivider = false,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: titleColor,
                  ),
                ),
                if (trailing != null)
                  trailing!
                else if (showChevron)
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.textTertiary,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
        if (showDivider)
          Divider(
            indent: 16,
            endIndent: 16,
            height: 0.5,
            thickness: 0.5,
            color: colors.borderSubtle,
          ),
      ],
    );
  }
}

class _PlanBadge extends StatelessWidget {
  final String plan;
  final String status;

  const _PlanBadge({required this.plan, required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final isPaid = AppLimits.isPaid(status);

    final label = AppLimits.planLabel(isPaid ? plan : null);
    final (Color bg, Color fg) = isPaid
        ? (AppColors.success.withValues(alpha: 0.12), AppColors.success)
        : (colors.surfaceAlt, colors.textTertiary);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    );
  }
}
