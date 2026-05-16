import 'package:flutter/material.dart';
import '../core/config/app_colors.dart';
import '../models/user.dart';
import 'avatar.dart';

/// Renders 1-2 overlapping member avatars inside a circle.
/// Falls back to a colored circle with the group's initial when no members.
class StackedAvatars extends StatelessWidget {
  final List<User> members;
  final String groupName;
  final String? groupColor;
  final double size;

  const StackedAvatars({
    super.key,
    required this.members,
    required this.groupName,
    this.groupColor,
    this.size = 56,
  });

  Color? _parseColor() {
    if (groupColor == null || groupColor!.isEmpty) return null;
    final hex = groupColor!.replaceFirst('#', '');
    if (hex.length != 6) return null;
    return Color(int.parse('FF$hex', radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    if (members.isEmpty) {
      final bgColor = _parseColor() ?? colors.surfaceAlt;
      final initial = groupName.isNotEmpty ? groupName[0].toUpperCase() : '?';
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bgColor,
        ),
        alignment: Alignment.center,
        child: Text(
          initial,
          style: TextStyle(
            fontSize: size * 0.38,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      );
    }

    if (members.length == 1) {
      return Avatar(
        imageUrl: members[0].avatarUrl,
        displayName: members[0].displayName,
        size: size,
      );
    }

    // 2+ members: two avatars offset diagonally
    final smallSize = size * 0.6;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            child: Avatar(
              imageUrl: members[0].avatarUrl,
              displayName: members[0].displayName,
              size: smallSize,
            ),
          ),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: colors.surface,
                  width: 1.5,
                ),
              ),
              child: Avatar(
                imageUrl: members[1].avatarUrl,
                displayName: members[1].displayName,
                size: smallSize,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
