import 'package:flutter/material.dart';
import '../core/config/app_colors.dart';
import '../models/models.dart';
import 'stacked_avatars.dart';

/// A circular group avatar with label, used in the groups filter bar.
class GroupCircle extends StatelessWidget {
  final Group group;
  final List<User> members;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const GroupCircle({
    super.key,
    required this.group,
    required this.members,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
  });

  Color? _parseColor() {
    if (group.color == null || group.color!.isEmpty) return null;
    final hex = group.color!.replaceFirst('#', '');
    if (hex.length != 6) return null;
    return Color(int.parse('FF$hex', radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final ringColor =
        isSelected ? (_parseColor() ?? colors.textPrimary) : colors.border;
    final ringWidth = isSelected ? 2.0 : 0.5;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
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
                border: Border.all(color: ringColor, width: ringWidth),
              ),
              padding: const EdgeInsets.all(3),
              child: ClipOval(
                child: StackedAvatars(
                  members: members,
                  groupName: group.name,
                  groupColor: group.color,
                  size: 56,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              group.name,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
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
}
