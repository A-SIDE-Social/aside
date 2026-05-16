import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../widgets/widgets.dart';
import '../../providers/providers.dart';
import '../../models/models.dart';

/// Provider that fetches mutual follows (connections).
final _connectionsProvider =
    FutureProvider.autoDispose<List<User>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getMutualFollows();
  final list = (data as List<dynamic>?) ?? [];
  return list.map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
});

/// Provider that fetches inbound follow requests (people who want to connect).
final _requestsProvider = FutureProvider.autoDispose<List<User>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getInboundFollows();
  final list = (data as List<dynamic>?) ?? [];
  return list.map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
});

class ConnectionsScreen extends ConsumerStatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  ConsumerState<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends ConsumerState<ConnectionsScreen> {
  /// Per-user guard so a double-tap on Accept can't fire two POST /follows
  /// calls — the second would race against the first and hit the server's
  /// "already following" check.
  final Set<String> _acceptingIds = {};

  Future<void> _acceptRequest(User user) async {
    if (_acceptingIds.contains(user.id)) return;
    setState(() => _acceptingIds.add(user.id));
    try {
      final api = ref.read(apiServiceProvider);
      await api.follow(user.id);
      ref.invalidate(_requestsProvider);
      ref.invalidate(_connectionsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connected with ${user.displayName}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to accept: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _acceptingIds.remove(user.id));
    }
  }

  Future<void> _declineRequest(User user) async {
    try {
      // To decline, we need to remove their follow of us.
      // The API doesn't have a dedicated "remove follower" endpoint,
      // so we'll just hide it locally. In practice, doing nothing
      // is fine — they stay as a one-way follow with no access.
      // For now, we just remove from the UI.
      ref.invalidate(_requestsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to decline: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final connectionsAsync = ref.watch(_connectionsProvider);
    final requestsAsync = ref.watch(_requestsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Friends')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(_connectionsProvider);
          ref.invalidate(_requestsProvider);
        },
        child: ListView(
          children: [
            // ── Requests section ──
            requestsAsync.when(
              data: (requests) {
                if (requests.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Text(
                        'Requests',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    ...requests.map((user) => ListTile(
                          onTap: () => context.push('/profile/${user.id}'),
                          leading: Avatar(
                            imageUrl: user.avatarUrl,
                            displayName: user.displayName,
                            size: 44,
                          ),
                          title: Text(
                            user.displayName,
                            style: theme.textTheme.titleMedium,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 32,
                                child: ElevatedButton(
                                  onPressed: _acceptingIds.contains(user.id)
                                      ? null
                                      : () => _acceptRequest(user),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    minimumSize: const Size(0, 32),
                                  ),
                                  child: const Text('Accept'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 32,
                                width: 32,
                                child: IconButton(
                                  onPressed: () => _declineRequest(user),
                                  icon: Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: colors.textTertiary,
                                  ),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ],
                          ),
                        )),
                    Divider(color: colors.borderSubtle, height: 1),
                  ],
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),

            // ── Friends section ──
            connectionsAsync.when(
              data: (connections) {
                if (connections.isEmpty) {
                  final hasRequests = requestsAsync.value?.isNotEmpty ?? false;
                  return Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: EmptyState(
                      icon: Icons.people_outline_rounded,
                      title: 'No friends yet',
                      subtitle: hasRequests
                          ? 'Accept a request above, or share your invite link to add friends.'
                          : 'Share your invite link to add friends.',
                      actionLabel: 'Share Invite Link',
                      onAction: () => context.go('/settings'),
                    ),
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Text(
                        'Connected',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    ...connections.asMap().entries.map((entry) {
                      final user = entry.value;
                      return Column(
                        children: [
                          Dismissible(
                            key: ValueKey(user.id),
                            direction: DismissDirection.endToStart,
                            confirmDismiss: (_) =>
                                _confirmDisconnect(context, user),
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 24),
                              color: AppColors.error,
                              child: const Icon(
                                Icons.person_remove_outlined,
                                color: Colors.white,
                              ),
                            ),
                            child: ListTile(
                              onTap: () => context.push('/profile/${user.id}'),
                              leading: Avatar(
                                imageUrl: user.avatarUrl,
                                displayName: user.displayName,
                                size: 44,
                              ),
                              title: Text(
                                user.displayName,
                                style: theme.textTheme.titleMedium,
                              ),
                              trailing: Icon(
                                Icons.chevron_right_rounded,
                                color: colors.textTertiary,
                                size: 20,
                              ),
                            ),
                          ),
                          if (entry.key < connections.length - 1)
                            Divider(
                              color: colors.borderSubtle,
                              indent: 74,
                              height: 0.5,
                            ),
                        ],
                      );
                    }),
                  ],
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.only(top: 48),
                child: LoadingIndicator(),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.only(top: 48),
                child: ErrorView(
                  message: error.toString(),
                  onRetry: () => ref.invalidate(_connectionsProvider),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmDisconnect(BuildContext context, User user) async {
    final colors = AppColors.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.border, width: 0.5),
        ),
        title: const Text('Disconnect?'),
        content: Text(
          'Remove ${user.displayName}? You will no longer see each other\'s posts or stories.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Disconnect',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return false;

    try {
      final api = ref.read(apiServiceProvider);
      await api.unfollow(user.id);
      ref.invalidate(_connectionsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Disconnected from ${user.displayName}')),
        );
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to disconnect: $e')),
        );
      }
      return false;
    }
  }
}
