import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/post_draft.dart';

const _kPostDraftsKey = 'post_drafts';

/// Holds the list of persisted post drafts.
///
/// Drafts are created when an upload stalls and the user chooses
/// "Save as Draft" in Create Post. They're shown as a banner on next open.
///
/// Riverpod 3 Notifier — `build()` returns the synchronous initial value
/// (empty list) and fires a background load that updates `state` when
/// SharedPreferences resolves.
class DraftNotifier extends Notifier<List<PostDraft>> {
  @override
  List<PostDraft> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kPostDraftsKey) ?? const [];
    state = raw
        .map((s) {
          try {
            return PostDraft.decode(s);
          } catch (_) {
            return null;
          }
        })
        .whereType<PostDraft>()
        .toList();
  }

  Future<void> refresh() => _load();

  Future<void> saveDraft(PostDraft draft) async {
    final next = [
      draft,
      ...state.where((d) => d.id != draft.id),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    state = next;
    await _persist();
  }

  Future<void> deleteDraft(String id) async {
    state = state.where((d) => d.id != id).toList();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kPostDraftsKey,
      state.map((d) => d.encode()).toList(),
    );
  }

  /// Dev/debug helper to clear all drafts.
  Future<void> clearAll() async {
    state = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPostDraftsKey);
  }
}

final draftProvider =
    NotifierProvider<DraftNotifier, List<PostDraft>>(DraftNotifier.new);

/// Convenience: raw JSON list (unused today, kept for future debugging).
Future<List<String>> readRawDrafts() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_kPostDraftsKey) ?? const [];
  // Silence unused-variable warnings in stripped builds.
  return raw.map((s) => jsonEncode(jsonDecode(s))).toList();
}
