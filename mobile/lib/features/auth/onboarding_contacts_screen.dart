import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../core/config/env.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';
import '../contacts/contact_sync_service.dart';

/// Post-registration screen that encourages new users to find friends
/// from their phone contacts before landing on the (empty) home feed.
class OnboardingContactsScreen extends ConsumerStatefulWidget {
  const OnboardingContactsScreen({super.key});

  @override
  ConsumerState<OnboardingContactsScreen> createState() =>
      _OnboardingContactsScreenState();
}

class _OnboardingContactsScreenState
    extends ConsumerState<OnboardingContactsScreen> {
  bool _syncing = false;
  bool _synced = false;
  String? _error;
  List<_ContactMatch> _matches = [];

  void _goHome() => context.go('/');

  Future<void> _syncContacts() async {
    setState(() {
      _syncing = true;
      _error = null;
    });

    try {
      final hashes = await ContactSyncService.getHashedContacts();
      if (hashes == null) {
        setState(() {
          _syncing = false;
          _error = 'Contacts permission is required to find friends.';
        });
        return;
      }

      if (hashes.isEmpty) {
        setState(() {
          _syncing = false;
          _synced = true;
          _matches = [];
        });
        return;
      }

      final api = ref.read(apiServiceProvider);
      final data = await api.syncContacts(hashes);
      final list = (data as List<dynamic>?) ?? [];

      setState(() {
        _syncing = false;
        _synced = true;
        _matches = list.map((e) {
          final m = e as Map<String, dynamic>;
          return _ContactMatch(
            user: User.fromJson(m),
            isMutual: m['is_mutual'] as bool? ?? false,
          );
        }).toList();
      });
    } catch (e) {
      setState(() {
        _syncing = false;
        _error = 'Something went wrong. You can try again from Settings later.';
      });
    }
  }

  Future<void> _connect(String userId, int index) async {
    try {
      final api = ref.read(apiServiceProvider);
      final result = await api.follow(userId);
      final isMutual =
          (result as Map<String, dynamic>)['is_mutual'] as bool? ?? false;

      setState(() {
        _matches[index] = _ContactMatch(
          user: _matches[index].user,
          isMutual: isMutual,
          requested: !isMutual,
        );
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _syncing
              ? const LoadingIndicator(message: 'Checking your contacts...')
              : !_synced
                  ? _buildPrompt(theme, colors)
                  : _buildResults(theme, colors),
        ),
      ),
    );
  }

  Widget _buildPrompt(ThemeData theme, AppColorTokens colors) {
    return Column(
      children: [
        const Spacer(flex: 1),
        Icon(
          Icons.people_rounded,
          size: 64,
          color: colors.textTertiary,
        ),
        const SizedBox(height: 20),
        Text(
          'Find your friends',
          style: theme.textTheme.headlineMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        // Apple App Review (Guideline 5.1.2) requires the in-app
        // disclosure to be unambiguous about what's being uploaded
        // and what we'll do with it. Build 36 was rejected because
        // the previous copy ("checks which of your contacts are
        // here / never stored in plain text") didn't make the
        // server upload explicit enough. Lead with the upload, name
        // what's uploaded, name what we do with it.
        Text(
          'To find your friends already on ${Env.appName}, the app will '
          'upload anonymized codes derived from the phone numbers and email '
          "addresses in your contacts to our server. We can match these "
          "codes against other users without being able to read your "
          'original contacts.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.textSecondary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          "Your raw contacts never leave your device — only the anonymized "
          "codes. We'll show you which of your contacts are on "
          "${Env.appName}; you decide who to connect with. We never "
          "auto-follow on your behalf.",
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.textTertiary,
          ),
          textAlign: TextAlign.center,
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(
            _error!,
            style: TextStyle(color: AppColors.error, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 28),
        ElevatedButton.icon(
          onPressed: _syncContacts,
          icon: const Icon(Icons.cloud_upload_outlined, size: 20),
          label: const Text('Upload & find friends'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _goHome,
          child: Text(
            'Skip for now',
            style: TextStyle(color: colors.textTertiary),
          ),
        ),
        const Spacer(flex: 2),
      ],
    );
  }

  Widget _buildResults(ThemeData theme, AppColorTokens colors) {
    return Column(
      children: [
        const SizedBox(height: 16),
        if (_matches.isEmpty) ...[
          const Spacer(flex: 2),
          Icon(
            Icons.people_outline_rounded,
            size: 64,
            color: colors.textTertiary,
          ),
          const SizedBox(height: 24),
          Text(
            'No friends found yet',
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'None of your contacts are on ${Env.appName} yet. Share your invite link to bring them in!',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () => context.go('/settings'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text('Share Invite Link'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _goHome,
            child: Text(
              'Go to Home',
              style: TextStyle(color: colors.textTertiary),
            ),
          ),
          const Spacer(flex: 3),
        ] else ...[
          Text(
            '${_matches.length} friend${_matches.length == 1 ? '' : 's'} found!',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Connect with them to share posts and messages.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: _matches.length,
              separatorBuilder: (_, __) => Divider(
                color: colors.borderSubtle,
                indent: 74,
                height: 0.5,
              ),
              itemBuilder: (context, index) {
                final match = _matches[index];
                return ListTile(
                  leading: Avatar(
                    imageUrl: match.user.avatarUrl,
                    displayName: match.user.displayName,
                    size: 44,
                  ),
                  title: Text(
                    match.user.displayName,
                    style: theme.textTheme.titleMedium,
                  ),
                  trailing: match.isMutual
                      ? Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.success,
                          size: 22,
                        )
                      : match.requested
                          ? OutlinedButton(
                              onPressed: null,
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 32),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                              ),
                              child: const Text('Requested'),
                            )
                          : ElevatedButton(
                              onPressed: () => _connect(match.user.id, index),
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(0, 32),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                              ),
                              child: const Text('Connect'),
                            ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: ElevatedButton(
              onPressed: _goHome,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
              child: const Text('Continue'),
            ),
          ),
        ],
      ],
    );
  }
}

class _ContactMatch {
  final User user;
  final bool isMutual;
  final bool requested;

  _ContactMatch({
    required this.user,
    this.isMutual = false,
    this.requested = false,
  });
}
