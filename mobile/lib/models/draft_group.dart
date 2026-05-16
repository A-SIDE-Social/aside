import 'user.dart';

/// A group DM the user has composed but not yet sent a message in.
///
/// Group conversations are created *lazily* on the server — the row
/// doesn't exist until the first message is sent. Until then, the
/// selected members and name live only in this in-memory struct,
/// passed through the router as `extra` from the group composer to
/// the conversation detail screen. Abandoning the draft (navigating
/// away without sending) is free: nothing to clean up server-side.
///
/// This replaces the earlier eager-creation flow where tapping
/// "Create" on the composer persisted an empty conversation row. That
/// approach produced two bugs: brand-new groups were hidden from the
/// conversations list (filtered by `last_message_at IS NOT NULL`) —
/// so users couldn't see what they just created and occasionally
/// re-ran the composer, stacking up duplicate empty rows in the DB.
class DraftGroup {
  final String name;
  final List<User> members;

  const DraftGroup({required this.name, required this.members});
}
