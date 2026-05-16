// Phase 1g + 1f: serialization format for E2EE message plaintexts.
//
// The Double Ratchet (1:1) and Sender Keys (group) both transport an
// opaque `Uint8List` plaintext. We wrap it in a versioned JSON
// schema so we can add fields without breaking old builds.
//
// Shape (user-visible messages):
//   { "v": 1, "t": "text",  "body": "..." }
//   { "v": 1, "t": "image",
//     "attachment": {
//       "key":      "dm/<uuid>",
//       "file_key": "<base64 32 bytes>",
//       "mime":     "image/jpeg"
//     },
//     "caption":  "optional" }
//
// Shape (Phase 1f group control, invisible to UI):
//   { "v": 1, "t": "group_skdm",
//     "conv": "<group conversation uuid>",
//     "skdm": "<base64 bytes>" }
//
// SKDM control messages ride inside 1:1 Double Ratchet envelopes
// addressed at a specific recipient (envelope_type=signal_skdm on
// the wire + recipient_id set). The receiver decrypts the 1:1 layer
// like any other message, then this decoder dispatches on `t` to
// route the inner payload — group_skdm updates the sender-key
// store silently without creating a UI row.
//
// Pre-Phase-1g messages are raw UTF-8 text without the wrapper. The
// decode path handles both: if bytes don't parse as JSON with a
// recognizable `v/t`, we fall back to treating the whole thing as a
// legacy `body`. That keeps old threads working after the upgrade.

import 'dart:convert';
import 'dart:typed_data';

import '../../models/models.dart';

class EnvelopeContent {
  final String? body; // text message body, or caption on attachment
  final AttachmentRef? attachment;

  /// Phase 1f: when non-null, this envelope is a control message
  /// carrying a Sender Key Distribution Message. Receiver should
  /// feed `groupSkdmBytes` to [SignalClient.processGroupSenderKeyFrom]
  /// keyed by `groupSkdmConversationId` + the envelope's sender, and
  /// NOT render anything to the UI.
  final String? groupSkdmConversationId;
  final Uint8List? groupSkdmBytes;

  const EnvelopeContent({
    this.body,
    this.attachment,
    this.groupSkdmConversationId,
    this.groupSkdmBytes,
  });

  /// True iff this envelope is an SKDM control message.
  bool get isGroupSkdm => groupSkdmBytes != null;
}

/// Build a JSON envelope for a text-only message.
Uint8List encodeTextEnvelope(String body) {
  return Uint8List.fromList(utf8.encode(jsonEncode({
    'v': 1,
    't': 'text',
    'body': body,
  })));
}

/// Build a JSON envelope for an image attachment (optionally with
/// a caption). `ref.decryptedBytes` is ignored — the recipient will
/// fetch the ciphertext and decrypt it locally.
Uint8List encodeImageEnvelope(AttachmentRef ref, {String? caption}) {
  return Uint8List.fromList(utf8.encode(jsonEncode({
    'v': 1,
    't': 'image',
    'attachment': {
      'key': ref.key,
      'file_key': base64.encode(ref.fileKey),
      'mime': ref.mime,
    },
    if (caption != null && caption.isNotEmpty) 'caption': caption,
  })));
}

/// Phase 1f: build a control-message envelope that carries a Sender
/// Key Distribution Message. Wrapped in a 1:1 Double Ratchet session
/// and sent as a `signal_skdm` message with `recipient_id` set on the
/// server side — only the targeted recipient sees the row.
Uint8List encodeGroupSkdmEnvelope({
  required String groupConversationId,
  required Uint8List skdmBytes,
}) {
  return Uint8List.fromList(utf8.encode(jsonEncode({
    'v': 1,
    't': 'group_skdm',
    'conv': groupConversationId,
    'skdm': base64.encode(skdmBytes),
  })));
}

/// Inverse of the encode helpers — returns either a text body, an
/// attachment reference (+ optional caption), or a legacy body on
/// non-JSON plaintext. Never throws; malformed payloads fall back
/// to treating the raw bytes as a string.
EnvelopeContent decodeEnvelope(Uint8List plaintext) {
  final String text;
  try {
    text = utf8.decode(plaintext);
  } catch (_) {
    return const EnvelopeContent();
  }
  dynamic parsed;
  try {
    parsed = jsonDecode(text);
  } catch (_) {
    // Legacy raw-text message.
    return EnvelopeContent(body: text);
  }
  if (parsed is! Map) return EnvelopeContent(body: text);
  final m = parsed;
  if (m['v'] != 1) return EnvelopeContent(body: text);

  switch (m['t']) {
    case 'text':
      return EnvelopeContent(body: m['body'] as String?);
    case 'image':
      final att = m['attachment'];
      if (att is! Map) return EnvelopeContent(body: m['caption'] as String?);
      final key = att['key'] as String?;
      final fileKeyB64 = att['file_key'] as String?;
      final mime = att['mime'] as String?;
      if (key == null || fileKeyB64 == null || mime == null) {
        return EnvelopeContent(body: m['caption'] as String?);
      }
      return EnvelopeContent(
        body: m['caption'] as String?,
        attachment: AttachmentRef(
          key: key,
          fileKey: base64.decode(fileKeyB64),
          mime: mime,
        ),
      );
    case 'group_skdm':
      // Phase 1f control message. Both fields must parse; if either
      // is missing we silently fall back to empty content so the UI
      // doesn't crash — a malformed SKDM is a bug worth logging but
      // not worth taking down the whole thread.
      final conv = m['conv'] as String?;
      final skdmB64 = m['skdm'] as String?;
      if (conv == null || skdmB64 == null) return const EnvelopeContent();
      try {
        return EnvelopeContent(
          groupSkdmConversationId: conv,
          groupSkdmBytes: base64.decode(skdmB64),
        );
      } catch (_) {
        return const EnvelopeContent();
      }
    default:
      // Unknown type — graceful degradation, don't crash.
      return EnvelopeContent(body: text);
  }
}
