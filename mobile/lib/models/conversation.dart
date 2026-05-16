import 'dart:typed_data';

import 'user.dart';

/// A DM thread. Two shapes:
///   - **Direct** (`type == 'direct'`): 1:1 chat between the current user
///     and [otherUserId]. `name`, `createdBy`, and `members` are null.
///   - **Group** (`type == 'group'`): N-party chat (≤10). `name` is the
///     conversation name, `createdBy` is the creator (admin for now),
///     `members` is the full member list including the current user.
///     `otherUserId` / `otherDisplayName` / `otherAvatarUrl` are null.
class Conversation {
  final String id;
  final String type; // 'direct' | 'group'
  final DateTime createdAt;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final DateTime? lastReadAt;

  // Direct-only.
  final String? otherUserId;
  final String? otherDisplayName;
  final String? otherAvatarUrl;

  // Group-only.
  final String? name;
  final String? createdBy;
  final List<User>? members;

  // Phase 1d E2EE: locked at creation time. `true` means every
  // message in this conversation is sent as a libsignal ciphertext
  // envelope; the server rejects plaintext body/media_url posts.
  final bool isE2ee;
  final int epoch; // group rekey generation, unused for 1:1

  Conversation({
    required this.id,
    required this.type,
    required this.createdAt,
    this.lastMessageAt,
    required this.unreadCount,
    this.lastReadAt,
    this.otherUserId,
    this.otherDisplayName,
    this.otherAvatarUrl,
    this.name,
    this.createdBy,
    this.members,
    this.isE2ee = false,
    this.epoch = 0,
  });

  /// True if this is a group DM.
  bool get isGroup => type == 'group';

  /// Title to show in the conversation list / chat header.
  /// Groups use their name; directs use the other user's display name.
  String get title => isGroup ? (name ?? 'Group') : (otherDisplayName ?? '');

  /// Whether the viewing user created this group (i.e. can rename /
  /// add / remove members). Always false for directs.
  bool isCreator(String viewerId) => isGroup && createdBy == viewerId;

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['members'];
    return Conversation(
      id: json['id'] as String,
      type: json['conversation_type'] as String? ?? 'direct',
      createdAt: DateTime.parse(json['created_at'] as String),
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.parse(json['last_message_at'] as String)
          : null,
      unreadCount: int.tryParse(json['unread_count']?.toString() ?? '0') ?? 0,
      lastReadAt: json['last_read_at'] != null
          ? DateTime.parse(json['last_read_at'] as String)
          : null,
      otherUserId: json['other_user_id'] as String?,
      otherDisplayName: json['other_display_name'] as String?,
      otherAvatarUrl: json['other_avatar_url'] as String?,
      name: json['name'] as String?,
      createdBy: json['created_by'] as String?,
      members: rawMembers is List
          ? rawMembers
              .map((m) => User.fromJson(m as Map<String, dynamic>))
              .toList()
          : null,
      isE2ee: json['is_e2ee'] as bool? ?? false,
      epoch: json['epoch'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversation_type': type,
      'created_at': createdAt.toIso8601String(),
      'last_message_at': lastMessageAt?.toIso8601String(),
      'unread_count': unreadCount,
      'last_read_at': lastReadAt?.toIso8601String(),
      'other_user_id': otherUserId,
      'other_display_name': otherDisplayName,
      'other_avatar_url': otherAvatarUrl,
      'name': name,
      'created_by': createdBy,
      'members': members?.map((m) => m.toJson()).toList(),
      'is_e2ee': isE2ee,
      'epoch': epoch,
    };
  }
}

/// Attachment reference embedded in an E2EE message envelope. The
/// server stores only the ciphertext blob at [key]; [fileKey] is
/// the AEAD key needed to decrypt it and only ever exists in the
/// envelope (which is itself Double-Ratchet-encrypted). Decrypted
/// bytes cache in [decryptedBytes] once the recipient has fetched
/// + decrypted the blob for rendering.
class AttachmentRef {
  final String key; // "dm/<uuid>"
  final Uint8List fileKey; // 32 bytes — the AEAD key for the blob
  final String mime; // "image/jpeg", "image/png", ...
  final Uint8List? decryptedBytes; // populated after fetch + decrypt

  const AttachmentRef({
    required this.key,
    required this.fileKey,
    required this.mime,
    this.decryptedBytes,
  });

  AttachmentRef copyWith({Uint8List? decryptedBytes}) {
    return AttachmentRef(
      key: key,
      fileKey: fileKey,
      mime: mime,
      decryptedBytes: decryptedBytes ?? this.decryptedBytes,
    );
  }
}

class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final String? body;
  final String? mediaUrl;
  final DateTime createdAt;
  final String senderDisplayName;
  final String? senderAvatarUrl;

  // Phase 1d/1e E2EE envelope. Non-null only for messages sent on
  // conversations where `is_e2ee = true`. The UI decrypts
  // [ciphertextBase64] into a synthesized [body] via SignalClient
  // before display; legacy plaintext messages keep [body] populated
  // on the wire.
  final String? ciphertextBase64;
  final String? envelopeType; // legacy_plaintext | signal_1to1 | signal_group
  final int? protocolVersion; // CiphertextMessageType: 2=PKM, 3=SignalMessage

  // Phase 1g: E2EE attachment. Populated client-side from the
  // decrypted envelope's JSON payload; never round-trips to the
  // server. Mutually compatible with [body] (caption + image).
  final AttachmentRef? attachment;

  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.body,
    this.mediaUrl,
    required this.createdAt,
    required this.senderDisplayName,
    this.senderAvatarUrl,
    this.ciphertextBase64,
    this.envelopeType,
    this.protocolVersion,
    this.attachment,
  });

  /// True iff this message arrived as a libsignal ciphertext envelope
  /// and hasn't yet been decrypted into [body]. The UI layer uses
  /// this to branch between rendering plaintext and kicking off
  /// SignalClient.decryptMessageFrom.
  bool get isEncryptedEnvelope =>
      ciphertextBase64 != null &&
      envelopeType != null &&
      envelopeType != 'legacy_plaintext';

  Message copyWithDecryptedBody(String decrypted) {
    return Message(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      body: decrypted,
      mediaUrl: mediaUrl,
      createdAt: createdAt,
      senderDisplayName: senderDisplayName,
      senderAvatarUrl: senderAvatarUrl,
      ciphertextBase64: ciphertextBase64,
      envelopeType: envelopeType,
      protocolVersion: protocolVersion,
      attachment: attachment,
    );
  }

  Message copyWithEnvelope({
    String? body,
    AttachmentRef? attachment,
  }) {
    return Message(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      body: body ?? this.body,
      mediaUrl: mediaUrl,
      createdAt: createdAt,
      senderDisplayName: senderDisplayName,
      senderAvatarUrl: senderAvatarUrl,
      ciphertextBase64: ciphertextBase64,
      envelopeType: envelopeType,
      protocolVersion: protocolVersion,
      attachment: attachment ?? this.attachment,
    );
  }

  Message withAttachmentBytes(Uint8List bytes) {
    if (attachment == null) return this;
    return copyWithEnvelope(
      attachment: attachment!.copyWith(decryptedBytes: bytes),
    );
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String,
      body: json['body'] as String?,
      mediaUrl: json['media_url'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      senderDisplayName: json['sender_display_name'] as String? ?? '',
      senderAvatarUrl: json['sender_avatar_url'] as String?,
      ciphertextBase64: json['ciphertext'] as String?,
      envelopeType: json['envelope_type'] as String?,
      protocolVersion: json['protocol_version'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'sender_id': senderId,
      'body': body,
      'media_url': mediaUrl,
      'created_at': createdAt.toIso8601String(),
      'sender_display_name': senderDisplayName,
      'sender_avatar_url': senderAvatarUrl,
      if (ciphertextBase64 != null) 'ciphertext': ciphertextBase64,
      if (envelopeType != null) 'envelope_type': envelopeType,
      if (protocolVersion != null) 'protocol_version': protocolVersion,
    };
  }
}
