import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

/// Provider that fetches and caches the conversations list.
///
/// Not auto-disposed: returning to the conversations tab feels instant.
final conversationsProvider = FutureProvider<List<Conversation>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getConversations();
  final list = (data as List<dynamic>?) ?? [];
  final conversations = list
      .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
      .toList();
  conversations.sort((a, b) {
    final aTime = a.lastMessageAt ?? a.createdAt;
    final bTime = b.lastMessageAt ?? b.createdAt;
    return bTime.compareTo(aTime);
  });
  return conversations;
});

/// Provider that fetches mutual follows for the new-conversation sheet.
final mutualFollowsProvider = FutureProvider<List<User>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getMutualFollows();
  final list = (data as List<dynamic>?) ?? [];
  return list.map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
});

class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key});

  @override
  ConsumerState<ConversationsScreen> createState() =>
      _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  StreamSubscription<Map<String, dynamic>>? _socketSub;

  @override
  void initState() {
    super.initState();
    // Refresh the list whenever ANY new message arrives — don't
    // filter by conversation here; a message might belong to a
    // conversation we haven't seen yet (first-ever DM). Invalidate
    // the provider and the list re-fetches, showing the
    // conversation at the top with the updated last_message_at +
    // unread count.
    _socketSub = ref.read(socketServiceProvider).newMessages.listen((_) {
      if (!mounted) return;
      ref.invalidate(conversationsProvider);
    });
  }

  @override
  void dispose() {
    _socketSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(conversationsProvider);
    await ref.read(conversationsProvider.future);
  }

  String _timeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${(diff.inDays / 7).floor()}w';
  }

  void _showNewConversationSheet() {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) {
            return Consumer(
              builder: (context, ref, _) {
                final mutualFollows = ref.watch(mutualFollowsProvider);
                return Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.textTertiary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'New Message',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Divider(
                      height: 0.5,
                      thickness: 0.5,
                      color: colors.border,
                    ),
                    Expanded(
                      child: mutualFollows.when(
                        loading: () => const LoadingIndicator(),
                        error: (e, _) => ErrorView(
                          message: 'Failed to load contacts',
                          onRetry: () => ref.invalidate(mutualFollowsProvider),
                        ),
                        data: (users) {
                          if (users.isEmpty) {
                            return const EmptyState(
                              icon: Icons.people_outline_rounded,
                              title: 'No mutual follows',
                              subtitle:
                                  'Follow people who follow you back to message them',
                            );
                          }
                          return ListView.builder(
                            controller: scrollController,
                            // +1 for the "New group" row at the top.
                            itemCount: users.length + 1,
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                return ListTile(
                                  leading: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: colors.surfaceAlt,
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Icons.group_add_outlined,
                                      color: colors.textSecondary,
                                    ),
                                  ),
                                  title: Text(
                                    'New group',
                                    style:
                                        theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    'Up to 10 people',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.textTertiary,
                                    ),
                                  ),
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    context.push('/conversations/new-group');
                                  },
                                );
                              }
                              final user = users[index - 1];
                              return ListTile(
                                leading: Avatar(
                                  imageUrl: user.avatarUrl,
                                  displayName: user.displayName,
                                  size: 44,
                                ),
                                title: Text(
                                  user.displayName,
                                  style: theme.textTheme.titleMedium,
                                ),
                                onTap: () => _startConversation(user),
                              );
                            },
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

  Future<void> _startConversation(User user) async {
    Navigator.of(context).pop(); // close bottom sheet
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.createConversation(user.id);
      final conversation = Conversation.fromJson(data as Map<String, dynamic>);
      if (mounted) {
        await context.push('/conversations/${conversation.id}');
        // Refresh list when returning from conversation
        ref.invalidate(conversationsProvider);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start conversation')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final conversations = ref.watch(conversationsProvider);
    final currentUserId = ref.watch(authProvider).user?.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showNewConversationSheet,
        child: const Icon(Icons.edit_outlined, size: 20),
      ),
      body: conversations.when(
        loading: () => const LoadingIndicator(),
        error: (e, _) => ErrorView(
          message: 'Failed to load messages: $e',
          onRetry: () => ref.invalidate(conversationsProvider),
        ),
        data: (convos) {
          if (convos.isEmpty) {
            return const EmptyState(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'No messages yet',
              subtitle: 'Start a conversation with your friends',
            );
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            color: colors.textPrimary,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: convos.length,
              separatorBuilder: (context, index) => Divider(
                indent: 74,
                height: 0.5,
                thickness: 0.5,
                color: colors.borderSubtle,
              ),
              itemBuilder: (context, index) {
                final convo = convos[index];
                return _ConversationTile(
                  conversation: convo,
                  currentUserId: currentUserId,
                  colors: colors,
                  theme: theme,
                  timeAgo: _timeAgo(
                    convo.lastMessageAt ?? convo.createdAt,
                  ),
                  onTap: () async {
                    await context.push('/conversations/${convo.id}');
                    ref.invalidate(conversationsProvider);
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.currentUserId,
    required this.colors,
    required this.theme,
    required this.timeAgo,
    required this.onTap,
  });

  final Conversation conversation;
  final String? currentUserId;
  final AppColorTokens colors;
  final ThemeData theme;
  final String timeAgo;
  final VoidCallback onTap;

  /// Leading widget: single avatar for 1:1, stacked avatars for group
  /// (using any 2 members that aren't the current user so you see
  /// *their* faces, not your own).
  Widget _buildLeading() {
    if (!conversation.isGroup) {
      return Avatar(
        imageUrl: conversation.otherAvatarUrl,
        displayName: conversation.otherDisplayName ?? '?',
        size: 44,
      );
    }
    final members = conversation.members ?? [];
    final others = members.where((m) => m.id != currentUserId).toList();
    return StackedAvatars(
      members: others,
      groupName: conversation.name ?? '?',
      size: 44,
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _buildLeading(),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conversation.title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  timeAgo,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textTertiary,
                  ),
                ),
                const SizedBox(height: 4),
                if (conversation.unreadCount > 0)
                  Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: colors.textPrimary,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      conversation.unreadCount > 99
                          ? '99+'
                          : '${conversation.unreadCount}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: colors.surface,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
