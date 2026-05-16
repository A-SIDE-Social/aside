import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../core/config/env.dart';
import '../../widgets/widgets.dart';
import '../../providers/providers.dart';
import '../../models/models.dart';
import 'contact_sync_service.dart';

class ContactSyncScreen extends ConsumerStatefulWidget {
  const ContactSyncScreen({super.key});

  @override
  ConsumerState<ContactSyncScreen> createState() => _ContactSyncScreenState();
}

class _ContactSyncScreenState extends ConsumerState<ContactSyncScreen> {
  bool _syncing = false;
  bool _synced = false;
  String? _error;
  List<_ContactMatch> _matches = [];

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
        _error = 'Failed to sync contacts. Please try again.';
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

      if (mounted && isMutual) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected with ${_matches[index].user.displayName}'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Find Friends')),
      body: _syncing
          ? const LoadingIndicator(message: 'Checking your contacts...')
          : !_synced
              ? _buildPrompt(theme, colors)
              : _buildResults(theme, colors),
    );
  }

  Widget _buildPrompt(ThemeData theme, AppColorTokens colors) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.contacts_rounded,
            size: 56,
            color: colors.textTertiary,
          ),
          const SizedBox(height: 20),
          Text(
            'Find friends on ${Env.appName}',
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          // Disclosure copy mirrors the onboarding screen — see
          // comment there for the App Review history. Critical bits:
          // (1) say "uploaded to our server", (2) say what's
          // uploaded (anonymized codes derived from contacts, not
          // raw contacts), (3) say what we do with the upload (show
          // matches; no auto-follow). Build 40 swapped "hashes" for
          // "anonymized codes" — same disclosure, layperson wording.
          Text(
            'To find your friends, the app will upload anonymized codes '
            'derived from the phone numbers and email addresses in your '
            "contacts to our server. We can match these codes against "
            "other users without being able to read your original contacts.",
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "Your raw contacts never leave your device — only the anonymized "
            "codes. We'll show you which contacts are on ${Env.appName}; "
            "you decide who to connect with. We never auto-follow on your "
            "behalf.",
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
              minimumSize: const Size(240, 48),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme, AppColorTokens colors) {
    if (_matches.isEmpty) {
      return EmptyState(
        icon: Icons.people_outline_rounded,
        title: 'No friends found yet',
        subtitle:
            'None of your contacts are on ${Env.appName} yet. Share your invite link to bring them in!',
        actionLabel: 'Open Settings',
        onAction: () => context.go('/settings'),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _matches.length,
      separatorBuilder: (_, __) =>
          Divider(color: colors.borderSubtle, indent: 74, height: 0.5),
      itemBuilder: (context, index) {
        final match = _matches[index];
        return ListTile(
          onTap: () => context.push('/profile/${match.user.id}'),
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
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: const Text('Requested'),
                    )
                  : ElevatedButton(
                      onPressed: () => _connect(match.user.id, index),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: const Text('Connect'),
                    ),
        );
      },
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
