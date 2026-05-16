import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';
import 'conversations_screen.dart' show mutualFollowsProvider;

/// Group DM composer. Pick 1–9 mutual follows, name the group, create.
///
/// Backend enforces: all members must be mutual follows, max 10 total
/// (creator + 9), name 1–50 chars. We mirror those rules client-side
/// so errors surface before the POST when possible.
class GroupComposerScreen extends ConsumerStatefulWidget {
  const GroupComposerScreen({super.key});

  @override
  ConsumerState<GroupComposerScreen> createState() =>
      _GroupComposerScreenState();
}

class _GroupComposerScreenState extends ConsumerState<GroupComposerScreen> {
  static const int _maxOtherMembers = 9; // creator + 9 = 10 cap
  static const int _maxNameLength = 50;

  final _nameController = TextEditingController();
  final Set<String> _selected = {};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _selected.isNotEmpty && _nameController.text.trim().isNotEmpty;

  void _create() {
    final name = _nameController.text.trim();
    if (name.isEmpty || _selected.isEmpty) return;

    // Build the draft from the selected mutual follows. Server row is
    // NOT created here — it's materialized on first message send from
    // the detail screen (see ConversationDetailScreen._sendMessage).
    // Abandoning the draft costs nothing; the server never sees it.
    final mutuals = ref.read(mutualFollowsProvider).value ?? [];
    final members =
        mutuals.where((u) => _selected.contains(u.id)).toList(growable: false);
    final draft = DraftGroup(name: name, members: members);

    context.pushReplacement('/conversations/new-group/chat', extra: draft);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final mutualFollows = ref.watch(mutualFollowsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          TextButton(
            onPressed: _canSubmit ? _create : null,
            child: const Text('Next'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _nameController,
              maxLength: _maxNameLength,
              decoration: InputDecoration(
                hintText: 'Group name',
                filled: true,
                fillColor: colors.surfaceAlt,
                counterText: '',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: colors.border, width: 0.5),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: colors.border, width: 0.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      BorderSide(color: colors.textTertiary, width: 0.5),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  'Members',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_selected.length}/$_maxOtherMembers',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _selected.length >= _maxOtherMembers
                        ? AppColors.error
                        : colors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
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
                        'Follow people who follow you back to add them to a group',
                  );
                }
                return ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (context, index) {
                    final user = users[index];
                    final isSelected = _selected.contains(user.id);
                    final atCap = _selected.length >= _maxOtherMembers;
                    final enabled = isSelected || !atCap;

                    return CheckboxListTile(
                      value: isSelected,
                      enabled: enabled,
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            _selected.add(user.id);
                          } else {
                            _selected.remove(user.id);
                          }
                        });
                      },
                      secondary: Avatar(
                        imageUrl: user.avatarUrl,
                        displayName: user.displayName,
                        size: 40,
                      ),
                      title: Text(
                        user.displayName,
                        style: theme.textTheme.titleMedium,
                      ),
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
