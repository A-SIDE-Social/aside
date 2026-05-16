import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

/// Provider to fetch a specific user's connections with the requesting user's
/// relationship annotated on each row.
final userConnectionsProvider = FutureProvider.autoDispose
    .family<List<dynamic>, String>((ref, userId) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getUserConnections(userId);
  return (data as List<dynamic>?) ?? [];
});

/// Shows a bottom sheet listing [user]'s connections. Each row shows avatar,
/// name, and the authenticated user's connection status with that person.
void showUserConnectionsSheet(
  BuildContext context,
  String userId,
  String displayName,
) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _UserConnectionsSheet(
      userId: userId,
      displayName: displayName,
    ),
  );
}

class _UserConnectionsSheet extends ConsumerStatefulWidget {
  final String userId;
  final String displayName;

  const _UserConnectionsSheet({
    required this.userId,
    required this.displayName,
  });

  @override
  ConsumerState<_UserConnectionsSheet> createState() =>
      _UserConnectionsSheetState();
}

class _UserConnectionsSheetState extends ConsumerState<_UserConnectionsSheet> {
  final Set<String> _pendingFollowIds = {};

  Future<void> _sendFollow(String targetUserId) async {
    if (_pendingFollowIds.contains(targetUserId)) return;
    setState(() => _pendingFollowIds.add(targetUserId));
    try {
      final api = ref.read(apiServiceProvider);
      await api.follow(targetUserId);
      // Refresh the list to pick up the new relationship state
      ref.invalidate(userConnectionsProvider(widget.userId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _pendingFollowIds.remove(targetUserId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final connectionsAsync = ref.watch(userConnectionsProvider(widget.userId));
    final currentUserId = ref.watch(authProvider).user?.id;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.borderSubtle,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${widget.displayName}\u2019s Connections',
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ),
            const Divider(),
            Expanded(
              child: connectionsAsync.when(
                data: (users) {
                  if (users.isEmpty) {
                    return const Center(
                      child: EmptyState(
                        icon: Icons.people_outline_rounded,
                        title: 'No connections',
                        subtitle:
                            'This person hasn\u2019t connected with anyone yet.',
                      ),
                    );
                  }

                  return ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: users.length,
                    separatorBuilder: (_, __) => Divider(
                      color: colors.borderSubtle,
                      indent: 74,
                      height: 0.5,
                    ),
                    itemBuilder: (context, index) {
                      final user = users[index] as Map<String, dynamic>;
                      final id = user['id'] as String;
                      final name = user['display_name'] as String;
                      final avatarUrl = user['avatar_url'] as String?;
                      final isMutual = user['is_mutual'] == true;
                      final iFollowThem = user['i_follow_them'] == true;
                      final theyFollowMe = user['they_follow_me'] == true;
                      final isSelf = id == currentUserId;

                      return ListTile(
                        onTap: isSelf
                            ? null
                            : () {
                                Navigator.of(context).pop();
                                context.push('/profile/$id');
                              },
                        leading: Avatar(
                          imageUrl: avatarUrl,
                          displayName: name,
                          size: 44,
                        ),
                        title: Text(
                          isSelf ? '$name (You)' : name,
                          style: theme.textTheme.titleMedium,
                        ),
                        trailing: isSelf
                            ? null
                            : _buildStatusWidget(
                                id: id,
                                isMutual: isMutual,
                                iFollowThem: iFollowThem,
                                theyFollowMe: theyFollowMe,
                                colors: colors,
                                theme: theme,
                              ),
                      );
                    },
                  );
                },
                loading: () => const LoadingIndicator(),
                error: (e, _) => ErrorView(
                  message: e.toString(),
                  onRetry: () =>
                      ref.invalidate(userConnectionsProvider(widget.userId)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatusWidget({
    required String id,
    required bool isMutual,
    required bool iFollowThem,
    required bool theyFollowMe,
    required AppColorTokens colors,
    required ThemeData theme,
  }) {
    if (isMutual) {
      return Text(
        'Connected',
        style: TextStyle(
          fontSize: 13,
          color: colors.textTertiary,
        ),
      );
    }

    if (iFollowThem) {
      return SizedBox(
        height: 30,
        child: OutlinedButton(
          onPressed: null,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 30),
          ),
          child: const Text('Requested'),
        ),
      );
    }

    if (theyFollowMe) {
      return SizedBox(
        height: 30,
        child: ElevatedButton(
          onPressed:
              _pendingFollowIds.contains(id) ? null : () => _sendFollow(id),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 30),
          ),
          child: const Text('Accept'),
        ),
      );
    }

    return SizedBox(
      height: 30,
      child: ElevatedButton(
        onPressed:
            _pendingFollowIds.contains(id) ? null : () => _sendFollow(id),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 30),
        ),
        child: const Text('Connect'),
      ),
    );
  }
}
