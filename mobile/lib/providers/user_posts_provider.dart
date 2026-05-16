import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/post.dart';
import 'api_provider.dart';

/// Provider that fetches a user's posts by user ID.
///
/// Not auto-disposed: keeps the data cached when the user navigates away
/// so returning to a profile feels instant. Refresh via `ref.invalidate(...)`.
final userPostsProvider =
    FutureProvider.family<List<Post>, String>((ref, userId) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getUserPosts(userId);
  final list = data as List<dynamic>;
  return list.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
});
