import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

class FamilyManagementScreen extends ConsumerStatefulWidget {
  const FamilyManagementScreen({super.key});

  @override
  ConsumerState<FamilyManagementScreen> createState() =>
      _FamilyManagementScreenState();
}

class _FamilyManagementScreenState
    extends ConsumerState<FamilyManagementScreen> {
  @override
  void initState() {
    super.initState();
    ref.read(subscriptionProvider.notifier).refreshStatus();
  }

  Future<void> _addMember() async {
    final result = await showSearch<String?>(
      context: context,
      delegate: _UserSearchDelegate(ref),
    );
    if (result != null && mounted) {
      await ref.read(subscriptionProvider.notifier).addFamilyMember(result);
    }
  }

  Future<void> _removeMember(String userId, String displayName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove member'),
        content: Text(
          'Remove $displayName from your family plan? '
          'They will lose Pro access immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(subscriptionProvider.notifier).removeFamilyMember(userId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final sub = ref.watch(subscriptionProvider);
    final family = sub.familyInfo;

    return Scaffold(
      appBar: AppBar(title: const Text('Family Plan')),
      body: sub.isLoading
          ? const LoadingIndicator()
          : family == null
              ? const EmptyState(
                  icon: Icons.family_restroom_rounded,
                  title: 'No family group',
                  subtitle:
                      'Subscribe to a Family plan to share Pro with up to 5 people.',
                )
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    // Header
                    Text(
                      '${family.memberCount} of ${family.maxMembers} members',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),

                    // Members list
                    ...family.members.map((member) {
                      final memberId = member['id'] as String;
                      final isOwner = memberId == family.owner?['id'];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: AppCard(
                          child: Row(
                            children: [
                              Avatar(
                                imageUrl: member['avatar_url'] as String?,
                                displayName:
                                    member['display_name'] as String? ?? '',
                                size: 40,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      member['display_name'] as String? ?? '',
                                      style: theme.textTheme.titleSmall,
                                    ),
                                    if (isOwner)
                                      Text(
                                        'Owner',
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: colors.textTertiary,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (!isOwner && family.isOwner)
                                IconButton(
                                  icon: Icon(
                                    Icons.remove_circle_outline,
                                    color: AppColors.error,
                                    size: 20,
                                  ),
                                  onPressed: () => _removeMember(
                                    memberId,
                                    member['display_name'] as String? ?? '',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),

                    // Add member button
                    if (family.isOwner &&
                        family.memberCount < family.maxMembers) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _addMember,
                        icon: const Icon(Icons.person_add_outlined, size: 18),
                        label: const Text('Add Member'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                        ),
                      ),
                    ],

                    // Leave button (for non-owner members)
                    if (!family.isOwner) ...[
                      const SizedBox(height: 24),
                      TextButton(
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Leave family plan'),
                              content: const Text(
                                'You will lose Pro access immediately.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Leave'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true && mounted) {
                            await ref
                                .read(subscriptionProvider.notifier)
                                .leaveFamily();
                            if (context.mounted) context.pop();
                          }
                        },
                        child: Text(
                          'Leave Family Plan',
                          style: TextStyle(color: AppColors.error),
                        ),
                      ),
                    ],

                    if (sub.error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        sub.error!,
                        style: TextStyle(color: AppColors.error, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
    );
  }
}

class _UserSearchDelegate extends SearchDelegate<String?> {
  final WidgetRef _ref;
  _UserSearchDelegate(this._ref);

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () => query = '',
      ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _buildSearchResults(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildSearchResults(context);

  Widget _buildSearchResults(BuildContext context) {
    if (query.length < 2) {
      return const Center(child: Text('Type a name to search'));
    }

    return FutureBuilder<dynamic>(
      future: _ref.read(apiServiceProvider).searchUsers(query),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LoadingIndicator();
        }
        if (!snapshot.hasData) {
          return const Center(child: Text('No results'));
        }

        final users = snapshot.data as List<dynamic>? ?? [];
        if (users.isEmpty) {
          return const Center(child: Text('No users found'));
        }

        return ListView.builder(
          itemCount: users.length,
          itemBuilder: (context, index) {
            final user = users[index] as Map<String, dynamic>;
            return ListTile(
              leading: Avatar(
                imageUrl: user['avatar_url'] as String?,
                displayName: user['display_name'] as String? ?? '',
                size: 40,
              ),
              title: Text(user['display_name'] as String? ?? ''),
              onTap: () => close(context, user['id'] as String),
            );
          },
        );
      },
    );
  }
}
