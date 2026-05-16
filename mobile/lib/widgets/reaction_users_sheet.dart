// Sheet showing who reacted to a post with a specific emoji.
//
// Long-press an emoji chip in the ReactionsStrip and this opens —
// same modal style as the LikesSheet (drag handle, title, list of
// avatars + names) so the two surfaces feel like siblings.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_colors.dart';
import '../providers/providers.dart';
import 'avatar.dart';

Future<void> showReactionUsersSheet(
  BuildContext context, {
  required String postId,
  required String emoji,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ReactionUsersSheet(postId: postId, emoji: emoji),
  );
}

class _ReactionUsersSheet extends ConsumerStatefulWidget {
  final String postId;
  final String emoji;
  const _ReactionUsersSheet({required this.postId, required this.emoji});

  @override
  ConsumerState<_ReactionUsersSheet> createState() =>
      _ReactionUsersSheetState();
}

class _ReactionUsersSheetState extends ConsumerState<_ReactionUsersSheet> {
  late Future<List<dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref
        .read(apiServiceProvider)
        .getPostReactionUsers(widget.postId, widget.emoji);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (_, scrollController) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.borderSubtle,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title row: "Reacted with {emoji}". Earlier draft showed
          // the emoji twice (once as a leading glyph, once inside the
          // sentence) which read as a typo.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Reacted with ',
                  style: theme.textTheme.titleMedium,
                ),
                Text(widget.emoji, style: const TextStyle(fontSize: 22)),
              ],
            ),
          ),
          Divider(height: 1, color: colors.borderSubtle),
          Expanded(
            child: FutureBuilder<List<dynamic>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        "Couldn't load reactors. Pull down and try again.",
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.textTertiary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final users = snapshot.data ?? const [];
                if (users.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No reactions yet',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  controller: scrollController,
                  itemCount: users.length,
                  itemBuilder: (context, i) {
                    final u = users[i] as Map<String, dynamic>;
                    final id = u['id'] as String;
                    final name = (u['display_name'] as String?) ?? 'Someone';
                    final avatarUrl = u['avatar_url'] as String?;
                    return ListTile(
                      leading: Avatar(
                        imageUrl: avatarUrl,
                        displayName: name,
                        size: 36,
                      ),
                      title: Text(name, style: theme.textTheme.bodyLarge),
                      onTap: () {
                        Navigator.of(context).pop();
                        context.push('/profile/$id');
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
