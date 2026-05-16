import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

class GroupDetailScreen extends ConsumerStatefulWidget {
  final String groupId;

  const GroupDetailScreen({super.key, required this.groupId});

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  Group? _group;
  List<User> _members = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final groupsData = await api.getLists();
      final groups = (groupsData as List)
          .map((e) => Group.fromJson(e as Map<String, dynamic>))
          .toList();
      final group = groups.firstWhere((g) => g.id == widget.groupId);

      final membersData = await api.getListMembers(widget.groupId);
      final members = (membersData as List)
          .map((e) => User.fromJson(e as Map<String, dynamic>))
          .toList();

      setState(() {
        _group = group;
        _members = members;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _showEditDialog() {
    if (_group == null) return;

    final nameController = TextEditingController(text: _group!.name);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: AppColors.of(ctx).border, width: 0.5),
        ),
        title: const Text('Edit List'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(hintText: 'List name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              Navigator.of(ctx).pop();
              try {
                final api = ref.read(apiServiceProvider);
                await api.updateList(widget.groupId, name: name);
                await _load();
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to update list: $e')),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: AppColors.of(ctx).border, width: 0.5),
        ),
        title: const Text('Delete List'),
        content: const Text(
          'Are you sure you want to delete this list? Members will not be unfollowed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final api = ref.read(apiServiceProvider);
        await api.deleteList(widget.groupId);
        if (mounted) context.pop();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete list: $e')),
          );
        }
      }
    }
  }

  Future<void> _showManageMembersSheet() async {
    final api = ref.read(apiServiceProvider);

    // Load mutual follows to show as options.
    List<User> mutualFollows;
    try {
      final data = await api.getMutualFollows();
      mutualFollows = (data as List)
          .map((e) => User.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load follows')),
        );
      }
      return;
    }

    if (!mounted) return;

    final currentMemberIds = _members.map((m) => m.id).toSet();
    final selectedIds = Set<String>.from(currentMemberIds);

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
                    // Handle
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Manage Members',
                            style: theme.textTheme.titleLarge,
                          ),
                          TextButton(
                            onPressed: () async {
                              Navigator.of(ctx).pop();
                              try {
                                await api.setListMembers(
                                  widget.groupId,
                                  selectedIds.toList(),
                                );
                                await _load();
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content:
                                          Text('Failed to update members: $e'),
                                    ),
                                  );
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
                              subtitle:
                                  'You need mutual follows to add members to lists',
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              itemCount: mutualFollows.length,
                              itemBuilder: (ctx, index) {
                                final user = mutualFollows[index];
                                final isSelected =
                                    selectedIds.contains(user.id);

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
                                  // Groups UI is currently disabled
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_group?.name ?? 'List'),
        actions: [
          if (_group != null) ...[
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: _showEditDialog,
            ),
            IconButton(
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20, color: AppColors.error),
              onPressed: _deleteGroup,
            ),
          ],
        ],
      ),
      body: _loading
          ? const LoadingIndicator()
          : _error != null
              ? ErrorView(message: _error, onRetry: _load)
              : _members.isEmpty
                  ? EmptyState(
                      icon: Icons.people_outline_rounded,
                      title: 'No members',
                      subtitle: 'Add members from your mutual follows',
                      actionLabel: 'Manage Members',
                      onAction: _showManageMembersSheet,
                    )
                  : Column(
                      children: [
                        Expanded(
                          child: ListView.separated(
                            padding: const EdgeInsets.all(24),
                            itemCount: _members.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final member = _members[index];
                              return AppCard(
                                child: Row(
                                  children: [
                                    Avatar(
                                      imageUrl: member.avatarUrl,
                                      displayName: member.displayName,
                                      size: 40,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        member.displayName,
                                        style: theme.textTheme.titleMedium,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                          child: OutlinedButton(
                            onPressed: _showManageMembersSheet,
                            child: const Text('Manage Members'),
                          ),
                        ),
                      ],
                    ),
    );
  }
}
