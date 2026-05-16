import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_colors.dart';
import '../core/config/env.dart';

// ─── Copy ───────────────────────────────────────────────────────────
const _kWelcomeSubtitle = 'A private space for your real friends.';

const _kInviteCardTitle = 'Invite your friends';
const _kInviteCardBody =
    'You have a personal invite link. Share it with anyone you want '
    'to connect with — find it in Settings.';
const _kInviteCardButton = 'Open Settings';

const _kWidgetCardTitle = 'Add the home screen widget';

const _kDismissButton = 'Got it';

/// Shows the one-time welcome bottom sheet for new signups.
void showWelcomeSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _WelcomeSheet(),
  );
}

class _WelcomeSheet extends StatelessWidget {
  const _WelcomeSheet();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.textTertiary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Title
              Text(
                'Welcome to ${Env.appName}',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                _kWelcomeSubtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Invite card — opens Settings where the link card lives
              _WelcomeCard(
                icon: Icons.mail_outline_rounded,
                title: _kInviteCardTitle,
                body: _kInviteCardBody,
                button: _kInviteCardButton,
                onPressed: () {
                  Navigator.of(context).pop();
                  context.go('/settings');
                },
              ),
              const SizedBox(height: 12),

              // Home screen widget card (instructional, no button)
              _WelcomeCard(
                icon: Icons.widgets_outlined,
                title: _kWidgetCardTitle,
                body:
                    "Pin your friends' latest photos to your home screen. Long-press "
                    "your home screen \u2192 tap +, search for '${Env.appName}', then pick a size.",
              ),
              const SizedBox(height: 20),

              // Dismiss
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(_kDismissButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({
    required this.icon,
    required this.title,
    required this.body,
    this.button,
    this.onPressed,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? button;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: colors.textPrimary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
              height: 1.35,
            ),
          ),
          if (button != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: onPressed,
                child: Text(button!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
