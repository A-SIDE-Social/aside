import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_colors.dart';
import '../../core/config/constants.dart';
import '../../core/config/env.dart';
import '../../widgets/widgets.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';

/// Bumped when the user re-taps the Home tab in the bottom nav while already
/// on the feed — FeedScreen listens and animates the scroll view to the top.
class FeedScrollToTopSignal extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final feedScrollToTopSignalProvider =
    NotifierProvider<FeedScrollToTopSignal, int>(FeedScrollToTopSignal.new);

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowWelcome());
    // Build 38: tell the server we just viewed the feed so the
    // server-computed app-icon badge stops counting older posts as
    // unread. Fire-and-forget — UI doesn't block on this and a
    // failure just means the badge stays slightly stale.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(apiServiceProvider).markFeedSeen().catchError((_) {});
    });
  }

  /// Show the one-time welcome sheet for brand-new signups. Flag is flipped
  /// off *before* displaying so a crash mid-sheet doesn't cause re-show on
  /// next launch.
  Future<void> _maybeShowWelcome() async {
    // In debug mode, always show the welcome sheet for visual testing.
    if (kDebugMode) {
      if (!mounted) return;
      showWelcomeSheet(context);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('pending_welcome_sheet') != true) return;
    await prefs.setBool('pending_welcome_sheet', false);
    if (!mounted) return;
    showWelcomeSheet(context);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _deletePost(String postId) async {
    // Optimistic: remove from UI immediately
    ref.read(feedNotifierProvider.notifier).removePost(postId);
    try {
      final api = ref.read(apiServiceProvider);
      await api.deletePost(postId);
      // Also invalidate user posts so profile grid updates
      final currentUser = ref.read(authProvider).user;
      if (currentUser != null) {
        ref.invalidate(userPostsProvider(currentUser.id));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Post deleted')),
        );
      }
    } catch (e) {
      // Refetch on failure to restore the post
      ref.read(feedNotifierProvider.notifier).refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete post: $e')),
        );
      }
    }
  }

  Future<void> _editCaption(String postId, String caption) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.editPostCaption(postId, caption);
      await ref.read(feedNotifierProvider.notifier).refresh();
      final currentUser = ref.read(authProvider).user;
      if (currentUser != null) {
        ref.invalidate(userPostsProvider(currentUser.id));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Caption updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update caption: $e')),
        );
      }
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      final notifier = ref.read(feedNotifierProvider.notifier);
      if (notifier.hasMore) {
        notifier.loadMore();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final feedState = ref.watch(feedNotifierProvider);
    final groupsWithMembers = ref.watch(groupsWithMembersProvider);
    final selectedGroup = ref.watch(feedGroupFilterProvider);
    final currentUser = ref.watch(authProvider).user;

    // Re-tap of the Home tab: smooth-scroll to top if we have any offset.
    ref.listen<int>(feedScrollToTopSignalProvider, (_, __) {
      if (!_scrollController.hasClients) return;
      if (_scrollController.offset <= 0) return;
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(
          Env.appName,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 28),
            onPressed: () => context.push('/post/new'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(groupsWithMembersProvider);
          await ref.read(feedNotifierProvider.notifier).refresh();
        },
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            // Groups filter bar
            SliverToBoxAdapter(
              child: groupsWithMembers.when(
                data: (list) {
                  // If selected group was deleted, reset filter
                  if (selectedGroup != null &&
                      !list.any((g) => g.group.id == selectedGroup)) {
                    Future.microtask(() =>
                        ref.read(feedGroupFilterProvider.notifier).set(null));
                  }
                  return _GroupsFilterBar(
                    groups: list,
                    selectedGroupId: selectedGroup,
                    onSelect: (id) =>
                        ref.read(feedGroupFilterProvider.notifier).set(id),
                    onCreateGroup: () => _showCreateGroupDialog(context, ref),
                    onEditGroup: (id) async {
                      await context.push('/groups/$id');
                      ref.invalidate(groupsWithMembersProvider);
                    },
                  );
                },
                loading: () => const SizedBox(height: 106),
                error: (_, __) => const SizedBox.shrink(),
              ),
            ),

            // Feed content
            feedState.when(
              data: (posts) {
                if (posts.isEmpty) {
                  return const SliverFillRemaining(
                    child: EmptyState(
                      icon: Icons.photo_library_outlined,
                      title: 'No posts yet',
                      subtitle:
                          'Posts from people you follow will appear here.',
                    ),
                  );
                }

                return SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      if (index == posts.length) {
                        final notifier =
                            ref.read(feedNotifierProvider.notifier);
                        if (notifier.hasMore) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: LoadingIndicator(),
                          );
                        }
                        // Show the paywall banner only when the server
                        // told us there are actually older posts sitting
                        // behind the plan gate. Previously we showed the
                        // banner for every Free user at the end of their
                        // feed — even brand-new users with nothing past
                        // the 7-day cutoff — which read as a nag.
                        final isFree = !AppLimits.isPaid(
                          currentUser?.subscriptionStatus,
                        );
                        if (isFree &&
                            posts.isNotEmpty &&
                            notifier.hasOlderPosts) {
                          return const PaywallBanner();
                        }
                        return const SizedBox.shrink();
                      }

                      final post = posts[index];
                      final isOwn = post.userId == currentUser?.id;
                      return Column(
                        children: [
                          PostCard(
                            post: post,
                            isOwn: isOwn,
                            showCommentButton: true,
                            onUserTap: () =>
                                context.push('/profile/${post.userId}'),
                            onLike: () => ref
                                .read(feedNotifierProvider.notifier)
                                .toggleLike(post.id),
                            onReact: (emoji) => ref
                                .read(feedNotifierProvider.notifier)
                                .toggleReaction(post.id, emoji),
                            onDelete: isOwn ? () => _deletePost(post.id) : null,
                            onEditCaption: isOwn
                                ? (caption) => _editCaption(post.id, caption)
                                : null,
                          ),
                          Divider(color: colors.borderSubtle),
                        ],
                      );
                    },
                    childCount: posts.length + 1,
                  ),
                );
              },
              loading: () => const SliverFillRemaining(
                child: LoadingIndicator(),
              ),
              error: (error, _) => SliverFillRemaining(
                child: ErrorView(
                  message: error.toString(),
                  onRetry: () =>
                      ref.read(feedNotifierProvider.notifier).refresh(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showCreateGroupDialog(BuildContext context, WidgetRef ref) async {
  final nameController = TextEditingController();
  final colors = AppColors.of(context);
  final theme = Theme.of(context);

  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('New List'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Lists let you filter your feed to see posts from specific people.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'List name',
            ),
            textCapitalization: TextCapitalization.words,
            onSubmitted: (value) {
              final trimmed = value.trim();
              if (trimmed.isNotEmpty) Navigator.pop(ctx, trimmed);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final trimmed = nameController.text.trim();
            if (trimmed.isNotEmpty) Navigator.pop(ctx, trimmed);
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );

  if (name == null || !context.mounted) return;

  try {
    final api = ref.read(apiServiceProvider);
    final result = await api.createList(name);
    final groupId = (result as Map<String, dynamic>)['id'] as String;
    // Auto-select the new list
    ref.read(feedGroupFilterProvider.notifier).set(groupId);
    ref.invalidate(groupsWithMembersProvider);

    // Immediately show member picker
    if (context.mounted) {
      await _showAddMembersSheet(context, ref, groupId);
    }
    ref.invalidate(groupsWithMembersProvider);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create list: $e')),
      );
    }
  }
}

Future<void> _showAddMembersSheet(
  BuildContext context,
  WidgetRef ref,
  String groupId,
) async {
  final api = ref.read(apiServiceProvider);

  List<User> mutualFollows;
  try {
    final data = await api.getMutualFollows();
    mutualFollows = (data as List)
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to load follows')),
      );
    }
    return;
  }

  if (!context.mounted) return;

  final selectedIds = <String>{};

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          final colors = AppColors.of(ctx);

          return DraggableScrollableSheet(
            initialChildSize: 0.6,
            maxChildSize: 0.9,
            minChildSize: 0.3,
            expand: false,
            builder: (ctx, scrollController) {
              return Column(
                children: [
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Add Members',
                          style: theme.textTheme.titleLarge,
                        ),
                        TextButton(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            if (selectedIds.isNotEmpty) {
                              try {
                                await api.setListMembers(
                                  groupId,
                                  selectedIds.toList(),
                                );
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content:
                                          Text('Failed to add members: $e'),
                                    ),
                                  );
                                }
                              }
                            }
                          },
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: mutualFollows.isEmpty
                        ? const EmptyState(
                            icon: Icons.people_outline_rounded,
                            title: 'No mutual follows',
                            subtitle: 'You need mutual follows to add members',
                          )
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            itemCount: mutualFollows.length,
                            itemBuilder: (ctx, index) {
                              final user = mutualFollows[index];
                              final isSelected = selectedIds.contains(user.id);

                              return CheckboxListTile(
                                value: isSelected,
                                onChanged: (value) {
                                  setSheetState(() {
                                    if (value == true) {
                                      selectedIds.add(user.id);
                                    } else {
                                      selectedIds.remove(user.id);
                                    }
                                  });
                                },
                                secondary: Avatar(
                                  imageUrl: user.avatarUrl,
                                  displayName: user.displayName,
                                  size: 36,
                                ),
                                title: Text(
                                  user.displayName,
                                  style: theme.textTheme.titleMedium,
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          );
        },
      );
    },
  );
}

class _GroupsFilterBar extends StatelessWidget {
  final List<GroupWithMembers> groups;
  final String? selectedGroupId;
  final ValueChanged<String?> onSelect;
  final VoidCallback onCreateGroup;
  final ValueChanged<String> onEditGroup;

  const _GroupsFilterBar({
    required this.groups,
    this.selectedGroupId,
    required this.onSelect,
    required this.onCreateGroup,
    required this.onEditGroup,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return Container(
      height: 106,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.borderSubtle, width: 0.5),
        ),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        itemCount: groups.length + 2, // +1 for "New", +1 for "All"
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          if (index == 0) {
            // "New" circle
            return GestureDetector(
              onTap: onCreateGroup,
              child: SizedBox(
                width: 72,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colors.border,
                          width: 0.5,
                        ),
                      ),
                      child: Icon(
                        Icons.add,
                        color: colors.textSecondary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'New',
                      style: theme.textTheme.labelSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          if (index == 1) {
            // "All" circle
            final isAllSelected = selectedGroupId == null;
            return GestureDetector(
              onTap: () => onSelect(null),
              child: SizedBox(
                width: 72,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isAllSelected
                              ? colors.textPrimary
                              : colors.border,
                          width: isAllSelected ? 2.0 : 0.5,
                        ),
                      ),
                      child: Icon(
                        Icons.people_rounded,
                        color: isAllSelected
                            ? colors.textPrimary
                            : colors.textSecondary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'All',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight:
                            isAllSelected ? FontWeight.w600 : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          // Group circles
          final gm = groups[index - 2];
          final isSelected = selectedGroupId == gm.group.id;
          return GroupCircle(
            group: gm.group,
            members: gm.members,
            isSelected: isSelected,
            onTap: () => onSelect(isSelected ? null : gm.group.id),
            onLongPress: () => onEditGroup(gm.group.id),
          );
        },
      ),
    );
  }
}
