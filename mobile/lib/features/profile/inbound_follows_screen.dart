import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../widgets/widgets.dart';
import '../../providers/providers.dart';
import '../../models/models.dart';

/// Provider that fetches inbound (pending) follow requests.
final _inboundFollowsProvider =
    FutureProvider.autoDispose<List<User>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getInboundFollows();
  final list = data as List<dynamic>;
  return list.map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
});

class InboundFollowsScreen extends ConsumerStatefulWidget {
  const InboundFollowsScreen({super.key});

  @override
  ConsumerState<InboundFollowsScreen> createState() =>
      _InboundFollowsScreenState();
}

class _InboundFollowsScreenState extends ConsumerState<InboundFollowsScreen> {
  final Set<String> _loadingIds = {};

  Future<void> _followBack(User user) async {
    setState(() => _loadingIds.add(user.id));

    try {
      final api = ref.read(apiServiceProvider);
      await api.follow(user.id);
      ref.invalidate(_inboundFollowsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to follow back: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingIds.remove(user.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final inboundAsync = ref.watch(_inboundFollowsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Follow Requests'),
      ),
      body: inboundAsync.when(
        data: (users) {
          if (users.isEmpty) {
            return const EmptyState(
              icon: Icons.person_add_outlined,
              title: 'No follow requests',
              subtitle: 'When someone follows you, they will appear here.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(_inboundFollowsProvider);
            },
            child: ListView.separated(
              itemCount: users.length,
              separatorBuilder: (_, __) => Divider(color: colors.borderSubtle),
              itemBuilder: (context, index) {
                final user = users[index];
                final isLoading = _loadingIds.contains(user.id);

                return ListTile(
                  leading: GestureDetector(
                    onTap: () => context.push('/profile/${user.id}'),
                    child: Avatar(
                      imageUrl: user.avatarUrl,
                      displayName: user.displayName,
                      size: 44,
                    ),
                  ),
                  title: GestureDetector(
                    onTap: () => context.push('/profile/${user.id}'),
                    child: Text(
                      user.displayName,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  trailing: SizedBox(
                    width: 110,
                    height: 34,
                    child: ElevatedButton(
                      onPressed: isLoading ? null : () => _followBack(user),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        textStyle: theme.textTheme.labelLarge,
                      ),
                      child: isLoading
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colors.surface,
                              ),
                            )
                          : const Text('Follow Back'),
                    ),
                  ),
                );
              },
            ),
          );
        },
        loading: () => const LoadingIndicator(),
        error: (error, _) => ErrorView(
          message: error.toString(),
          onRetry: () => ref.invalidate(_inboundFollowsProvider),
        ),
      ),
    );
  }
}
