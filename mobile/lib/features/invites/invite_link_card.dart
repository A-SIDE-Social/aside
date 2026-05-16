import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config/app_colors.dart';
import '../../core/config/env.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

/// Self-contained "Invite Friends" card. Drop into any screen
/// (Settings is the primary site as of 1.3.0).
///
/// Renders the user's personal invite link plus copy / Share / QR /
/// New affordances. Owns its own state (regenerating spinner +
/// confirmation dialog flow) so callers don't need to wire anything
/// up beyond mounting it inside their layout.
class InviteLinkCard extends ConsumerStatefulWidget {
  const InviteLinkCard({super.key});

  @override
  ConsumerState<InviteLinkCard> createState() => _InviteLinkCardState();
}

class _InviteLinkCardState extends ConsumerState<InviteLinkCard> {
  bool _regenerating = false;

  void _copyLink(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Link copied'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _shareLink(BuildContext ctx, String url) async {
    final box = ctx.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text:
            'Join me on ${Env.appName} — a private photo sharing app for real friends. No ads, no algorithms.\n\n$url',
        sharePositionOrigin:
            box != null ? box.localToGlobal(Offset.zero) & box.size : Rect.zero,
      ),
    );
  }

  void _showQrCode(String url) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _QrSheet(url: url),
    );
  }

  Future<void> _regenerate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regenerate invite link?'),
        content: const Text(
          'Your current link and any QR codes you\'ve shared will stop working. People who haven\'t accepted yet won\'t be able to use the old link.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _regenerating = true);
    try {
      await ref.read(inviteLinkProvider.notifier).regenerate();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New link generated.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to regenerate: $e')),
      );
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inviteLinkAsync = ref.watch(inviteLinkProvider);
    return inviteLinkAsync.when(
      loading: () => const _LinkSkeleton(),
      error: (e, _) => ErrorView(
        message: 'Could not load your invite link.\n$e',
        onRetry: () => ref.invalidate(inviteLinkProvider),
      ),
      data: (link) => _LinkCardBody(
        url: link.url,
        regenerating: _regenerating,
        onCopy: () => _copyLink(link.url),
        onShare: (ctx) => _shareLink(ctx, link.url),
        onShowQr: () => _showQrCode(link.url),
        onRegenerate: _regenerating ? null : _regenerate,
      ),
    );
  }
}

class _LinkSkeleton extends StatelessWidget {
  const _LinkSkeleton();

  @override
  Widget build(BuildContext context) {
    return const AppCard(
      child: SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _LinkCardBody extends StatelessWidget {
  final String url;
  final bool regenerating;
  final VoidCallback onCopy;
  final void Function(BuildContext ctx) onShare;
  final VoidCallback onShowQr;
  final VoidCallback? onRegenerate;

  const _LinkCardBody({
    required this.url,
    required this.regenerating,
    required this.onCopy,
    required this.onShare,
    required this.onShowQr,
    required this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Invite Friends',
            style: theme.textTheme.titleSmall?.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          // URL row: monospace text in a tinted container with an
          // explicit copy icon button on the right. The container
          // itself is also tappable so the entire row reads as the
          // copy affordance — the icon button is for users who
          // expect a discrete control.
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: onCopy,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceAlt,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      url,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        letterSpacing: 0.2,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: onCopy,
                icon: Icon(
                  Icons.copy_rounded,
                  size: 20,
                  color: colors.textSecondary,
                ),
                tooltip: 'Copy link',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Three action buttons. We stack icon-over-label inside
          // each button instead of the default Material `.icon`
          // (which lays them out horizontally) — that layout was
          // wrapping "Share" and "New" onto two lines on 393pt
          // device widths. Vertical stack gives the text the full
          // button width so single-word labels never wrap.
          Row(
            children: [
              Expanded(
                child: Builder(
                  builder: (ctx) => _ActionButton(
                    icon: Icons.ios_share_rounded,
                    label: 'Share',
                    onPressed: () => onShare(ctx),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  icon: Icons.qr_code_rounded,
                  label: 'QR',
                  onPressed: onShowQr,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ActionButton(
                  icon: Icons.refresh_rounded,
                  label: 'New',
                  onPressed: onRegenerate,
                  busy: regenerating,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Anyone who taps your link or scans your QR sends you a connection request. You decide whether to accept. Regenerating makes the old link stop working.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small toolbar-style action button: outlined box with icon stacked
/// over a label. Designed to fit 3 across at typical phone widths
/// without text wrap.
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final disabled = onPressed == null;
    final fg = disabled ? colors.textTertiary : colors.textPrimary;

    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        minimumSize: const Size(0, 64),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, size: 20, color: fg),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: fg),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
          ),
        ],
      ),
    );
  }
}

class _QrSheet extends StatelessWidget {
  final String url;
  const _QrSheet({required this.url});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.borderSubtle,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Scan to send a request',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 24),
            // White card behind the QR so it stays scannable even in
            // dark mode — QR readers expect a high-contrast background.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: url,
                version: QrVersions.auto,
                size: 260,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              url,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
