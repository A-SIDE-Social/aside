import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import 'api_provider.dart';

class GroupWithMembers {
  final Group group;
  final List<User> members;

  GroupWithMembers({required this.group, required this.members});
}

/// Fetches all groups with their members preloaded for the filter bar.
///
/// Not auto-disposed: cached across navigation so the filter bar appears
/// instantly when returning to the feed.
final groupsWithMembersProvider =
    FutureProvider<List<GroupWithMembers>>((ref) async {
  final api = ref.watch(apiServiceProvider);
  final groupsData = await api.getLists();
  final groups = (groupsData as List)
      .map((e) => Group.fromJson(e as Map<String, dynamic>))
      .toList();

  final results = await Future.wait(
    groups.map((g) async {
      final membersData = await api.getListMembers(g.id);
      final members = (membersData as List)
          .map((e) => User.fromJson(e as Map<String, dynamic>))
          .toList();
      return GroupWithMembers(group: g, members: members);
    }),
  );
  return results;
});
