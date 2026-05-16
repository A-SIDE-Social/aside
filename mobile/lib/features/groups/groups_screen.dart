import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key});

  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen> {
  List<Group> _groups = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.getLists();
      final list = (data as List)
          .map((e) => Group.fromJson(e as Map<String, dynamic>))
          .toList();
      setState(() {
        _groups = list;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _showAddGroupDialog() {
    final nameController = TextEditingController();
    String? selectedColor;

    const presetColors = [
      '#FF6B6B',
      '#7ECBA1',
      '#F2C66D',
      '#6B9FFF',
      '#C084FC',
      '#F472B6',
      '#FB923C',
      '#38BDF8',
    ];

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final colors = AppColors.of(ctx);

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: colors.border, width: 0.5),
              ),
              title: const Text('New List'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(hintText: 'List name'),
                    textInputAction: TextInputAction.done,
                    autofocus: true,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Color',
                    style: Theme.of(ctx).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: presetColors.map((hex) {
                      final color = Color(
                        int.parse(hex.substring(1), radix: 16) + 0xFF000000,
                      );
                      final isSelected = selectedColor == hex;

                      return GestureDetector(
                        onTap: () {
                          setDialogState(() {
                            selectedColor = isSelected ? null : hex;
                          });
                        },
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: isSelected
                                ? Border.all(
                                    color: colors.textPrimary,
                                    width: 2,
                                  )
                                : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
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
                    await _createGroup(name, selectedColor);
                  },
                  child: const Text('Create'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _createGroup(String name, String? color) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.createList(name, color: color);
      await _loadGroups();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create list: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            onPressed: _showAddGroupDialog,
          ),
        ],
      ),
      body: _loading
          ? const LoadingIndicator()
          : _error != null
              ? ErrorView(message: _error, onRetry: _loadGroups)
              : _groups.isEmpty
                  ? EmptyState(
                      icon: Icons.group_outlined,
                      title: 'No lists yet',
                      subtitle: 'Create lists to organize who sees your posts',
                      actionLabel: 'Create List',
                      onAction: _showAddGroupDialog,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(24),
                      itemCount: _groups.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final group = _groups[index];
                        return _GroupCard(
                          group: group,
                          onTap: () => context.push('/groups/${group.id}'),
                        );
                      },
                    ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final Group group;
  final VoidCallback onTap;

  const _GroupCard({
    required this.group,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);

    final dotColor = group.color != null
        ? Color(
            int.parse(group.color!.substring(1), radix: 16) + 0xFF000000,
          )
        : colors.textTertiary;

    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              group.name,
              style: theme.textTheme.titleMedium,
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: colors.textTertiary,
            size: 20,
          ),
        ],
      ),
    );
  }
}
