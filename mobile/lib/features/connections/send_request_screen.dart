import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

/// Lookup of a single user by their personal invite slug. Used only
/// by [SendRequestScreen] — kept as a local FutureProvider so it
/// auto-disposes when the screen unmounts.
///
/// Family-keyed on the slug so multiple in-app deep-link taps in the
/// same session don't share state.
final _userBySlugProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, slug) async {
  final api = ref.watch(apiServiceProvider);
  return api.getUserBySlug(slug);
});

/// "Send request to [Name]?" confirmation screen, shown when an
/// existing A/SIDE user taps a personal invite link
/// (`<configured-app-url>/<slug>`) and the Universal Link / App Link
/// catches the URL.
///
/// Two terminal cases land back on the feed with a snackbar:
///   1. Send succeeds → "Connection request sent."
///   2. Already mutual / already following → "Already connected." /
///      "Already requested."
///
/// 404 (slug rotated or unknown) shows an inline message and a single
/// Close button — no automatic redirect. The user got here from a
/// Universal Link tap; we want to make it obvious the link is stale.
class SendRequestScreen extends ConsumerStatefulWidget {
  final String slug;

  const SendRequestScreen({super.key, required this.slug});

  @override
  ConsumerState<SendRequestScreen> createState() => _SendRequestScreenState();
}

class _SendRequestScreenState extends ConsumerState<SendRequestScreen> {
  bool _sending = false;

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final api = ref.read(apiServiceProvider);
      final result = await api.requestFromSlug(widget.slug);
      if (!mounted) return;
      final status = result['status'] as String?;
      final message = switch (status) {
        'requested' => 'Connection request sent.',
        'already_following' => 'Request already pending.',
        'already_mutual' => 'You\'re already connected.',
        'self' => 'That\'s your own invite link.',
        _ => 'Request sent.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      // Whether the request was new, duplicate, or self, the right
      // post-state for the user is the feed — same as today's invite-
      // redeem flow. Inbound-follows is also reasonable but feels
      // more useful for the *recipient*, not the sender.
      context.go('/');
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send request: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final userAsync = ref.watch(_userBySlugProvider(widget.slug));

    return Scaffold(
      appBar: AppBar(
        // Empty title — the screen IS the action, no need to name it
        // in the bar too. Back button (Cancel) is enough chrome.
        title: const Text(''),
      ),
      body: userAsync.when(
        loading: () => const LoadingIndicator(),
        error: (e, st) {
          // 404 → stale slug. Most likely the slug owner regenerated
          // their link. Anything else is a generic network/server error.
          final isNotFound = e is DioException && e.response?.statusCode == 404;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.link_off_rounded,
                    size: 48,
                    color: colors.textTertiary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isNotFound
                        ? 'This invite link is no longer valid.'
                        : 'Could not load this invite link.',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (isNotFound) ...[
                    const SizedBox(height: 8),
                    Text(
                      'The person may have changed their link. Ask them to share it again.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textTertiary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: () => context.go('/'),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          );
        },
        data: (user) {
          final displayName =
              (user['display_name'] as String?) ?? 'this person';
          final avatarUrl = user['avatar_url'] as String?;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const Spacer(),
                Avatar(
                  imageUrl: avatarUrl,
                  displayName: displayName,
                  size: 96,
                ),
                const SizedBox(height: 24),
                Text(
                  displayName,
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Send a connection request? They\'ll need to accept before you can see each other\'s posts.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _sending ? null : _send,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: _sending
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.surface,
                            ),
                          )
                        : const Text('Send Request'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: _sending ? null : () => context.go('/'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }
}
