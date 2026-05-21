import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../src/rust/api/attachments.dart' as rust_aead;

import '../../core/cache/image_cache_manager.dart';
import '../../core/config/app_colors.dart';
import '../../core/config/constants.dart';
import '../../core/crypto/key_storage.dart';
import '../../core/crypto/message_envelope.dart';
import '../../core/crypto/signal_client.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';
import 'conversations_screen.dart' show conversationsProvider;

/// Decrypts a list of messages in place.
///
///   - Legacy plaintext messages pass through untouched.
///   - Own-sent E2EE messages re-hydrate body from the local
///     plaintext cache (server stores ciphertext only; Double Ratchet
///     is one-way so we can't decrypt our own outgoing envelopes).
///   - Incoming E2EE messages get decrypted via SignalClient.
///   - Any decrypt that throws leaves body null so the UI can render
///     a "couldn't decrypt" placeholder rather than blocking the
///     whole list on one bad envelope.
Message _applyEnvelope(Message msg, String plaintextText) {
  final env = decodeEnvelope(Uint8List.fromList(utf8.encode(plaintextText)));
  return msg.copyWithEnvelope(body: env.body, attachment: env.attachment);
}

Future<List<Message>> _decryptMessages(
  List<Message> raw,
  SignalClient signal,
  KeyStorage storage,
  String ownUserId,
) async {
  debugPrint('[e2ee] decrypt pass: ${raw.length} messages, ownId=$ownUserId');

  // Pre-pass (Phase 1f): process any signal_skdm rows in this batch
  // BEFORE we attempt to decrypt signal_group rows from the same
  // senders. The server sorts messages newest-first, so in a batch
  // the group message can precede its own SKDM (an SKDM + a first
  // group message sent in quick succession end up at ~same created_
  // at). Without this pre-pass we'd hit "no sender-key record" on
  // the group message even though its SKDM is sitting three entries
  // later in the same list.
  //
  // Own-sent SKDMs are skipped — we already have our own chain in
  // storage from the send path, and the Double Ratchet is one-way
  // so we can't decrypt our own outgoing envelope anyway.
  for (final msg in raw) {
    if (msg.envelopeType != 'signal_skdm') continue;
    if (msg.senderId == ownUserId) continue;
    final cipher64 = msg.ciphertextBase64;
    if (cipher64 == null) continue;
    try {
      final cipher = base64.decode(cipher64);
      final inner = await signal.decryptMessageFrom(
        ownUserId,
        msg.senderId,
        msg.protocolVersion ?? 3,
        cipher,
      );
      final env = decodeEnvelope(inner);
      final groupConvId = env.groupSkdmConversationId;
      final skdmBytes = env.groupSkdmBytes;
      if (env.isGroupSkdm && groupConvId != null && skdmBytes != null) {
        await signal.processGroupSenderKeyFrom(
          senderUserId: msg.senderId,
          conversationId: groupConvId,
          skdmBytes: skdmBytes,
        );
        debugPrint(
          '[e2ee] SKDM processed: from=${msg.senderId} conv=$groupConvId',
        );
      }
    } catch (e) {
      debugPrint('[e2ee] SKDM process failed msg=${msg.id}: $e');
      // Swallow — a failed SKDM process just means future group
      // messages from this sender will fail to decrypt. User sees
      // "couldn't decrypt" placeholders, not a crash.
    }
  }

  final out = <Message>[];
  for (final msg in raw) {
    // Phase 1f: SKDMs are invisible in the UI. Processed in the
    // pre-pass above; here we just drop them from the output list
    // so they never render as empty bubbles.
    if (msg.envelopeType == 'signal_skdm') continue;

    if (!msg.isEncryptedEnvelope) {
      out.add(msg);
      continue;
    }
    // Cache lookup first — applies to both own-sent (never decryptable
    // by us again) AND incoming (we decrypted once on arrival and
    // cached; re-decrypting would rewind the Double Ratchet to an
    // earlier state and break future messages).
    try {
      final cached = await storage.loadPlaintext(msg.id);
      if (cached != null) {
        debugPrint('[e2ee] msg ${msg.id}: cache hit');
        out.add(_applyEnvelope(msg, cached));
        continue;
      }
    } catch (e) {
      debugPrint('[e2ee] msg ${msg.id}: loadPlaintext threw: $e');
      // Fall through — attempt decrypt if incoming, or leave empty if own.
    }

    if (msg.senderId == ownUserId) {
      // Own outgoing, no cache. Can't recover — ratchet is one-way.
      debugPrint('[e2ee] own msg ${msg.id}: cache miss, body empty');
      out.add(msg);
      continue;
    }

    // Incoming, no cache — first time we see it. Decrypt + cache.
    try {
      final ciphertextBytes = base64.decode(msg.ciphertextBase64!);
      Uint8List plaintext;
      if (msg.envelopeType == 'signal_group') {
        // Phase 1f: group Sender Keys. Requires the sender's record
        // to have been populated by a prior SKDM — handled by the
        // pre-pass above or by an earlier socket event.
        plaintext = await signal.decryptGroupMessage(
          senderUserId: msg.senderId,
          conversationId: msg.conversationId,
          ciphertext: ciphertextBytes,
        );
      } else {
        // signal_1to1 — pairwise Double Ratchet.
        plaintext = await signal.decryptMessageFrom(
          ownUserId,
          msg.senderId,
          msg.protocolVersion ?? 3,
          ciphertextBytes,
        );
      }
      final text = utf8.decode(plaintext);
      debugPrint(
        '[e2ee] msg ${msg.id}: decrypted ${plaintext.length} bytes '
        '(type=${msg.envelopeType})',
      );
      // Persist so re-fetches serve from cache (critical — re-running
      // the ratchet on an already-processed message breaks state).
      try {
        await storage.savePlaintext(msg.id, text);
      } catch (e) {
        debugPrint('[e2ee] msg ${msg.id}: savePlaintext threw: $e');
      }
      out.add(_applyEnvelope(msg, text));
    } catch (e) {
      debugPrint(
        '[e2ee] msg ${msg.id}: decrypt failed (type=${msg.envelopeType}): $e',
      );
      out.add(msg);
    }
  }
  debugPrint('[e2ee] decrypt pass done: ${out.length} messages returned');
  return out;
}

/// Result of loading messages, including paywall gate info.
class MessagesResult {
  final List<Message> messages;
  final bool hasOlderMessages;

  const MessagesResult({
    required this.messages,
    this.hasOlderMessages = false,
  });
}

/// Provider family for a conversation's messages (initial load).
final messagesProvider = FutureProvider.autoDispose
    .family<MessagesResult, String>((ref, conversationId) async {
  final api = ref.watch(apiServiceProvider);
  final data = await api.getMessages(conversationId) as Map<String, dynamic>;
  final list = (data['messages'] as List<dynamic>?) ?? [];
  final raw =
      list.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();

  // Decrypt any envelopes in place before the UI touches them.
  // If no one's authenticated yet we just pass through — callers
  // shouldn't see E2EE messages in that state anyway.
  final ownId = ref.watch(authProvider).user?.id;
  final messages = ownId == null
      ? raw
      : await _decryptMessages(
          raw,
          ref.read(signalClientProvider),
          ref.read(keyStorageProvider),
          ownId,
        );

  return MessagesResult(
    messages: messages,
    hasOlderMessages: data['has_older_messages'] as bool? ?? false,
  );
});

/// Provider family to fetch conversation metadata. Hits the
/// single-conversation endpoint (GET /v1/conversations/:id) so a
/// freshly-created conversation with no messages yet still loads —
/// the list endpoint filters those out via `last_message_at IS NOT
/// NULL`, which would leave `firstWhere` with nothing to match.
final conversationProvider = FutureProvider.autoDispose
    .family<Conversation, String>((ref, conversationId) async {
  final api = ref.watch(apiServiceProvider);
  final json = await api.getConversationById(conversationId);
  return Conversation.fromJson(json);
});

class ConversationDetailScreen extends ConsumerStatefulWidget {
  /// One of these MUST be non-null:
  ///   - `conversationId` for an existing server-persisted conversation
  ///   - `draft` for a new group composed but not yet sent
  const ConversationDetailScreen({
    super.key,
    this.conversationId,
    this.draft,
  }) : assert(conversationId != null || draft != null,
            'Either conversationId or draft must be provided');

  final String? conversationId;
  final DraftGroup? draft;

  @override
  ConsumerState<ConversationDetailScreen> createState() =>
      _ConversationDetailScreenState();
}

class _ConversationDetailScreenState
    extends ConsumerState<ConversationDetailScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final List<Message> _messages = [];
  String? _beforeCursor;
  bool _hasMore = true;
  bool _loadingMore = false;
  bool _sending = false;
  bool _hasOlderMessages = false;

  /// Becomes non-null once a draft is materialized on the server (after
  /// the first successful message send). In normal (non-draft) mode
  /// this stays null and we use `_convId!`.
  String? _materializedId;

  /// The effective conversation id — either the originally-passed id
  /// for existing conversations, or the materialized id for a draft
  /// that's been sent into. Null only while a draft is still pending
  /// its first send.
  String? get _convId => widget.conversationId ?? _materializedId;

  /// True while we're in pre-send draft mode (no server row yet).
  bool get _isDraft => widget.draft != null && _materializedId == null;

  /// Whether we've taken the initial seed from the messagesProvider.
  /// Tracked separately from `_messages.isEmpty` so that a conversation
  /// whose recent-window is empty (but full history is plan-gated)
  /// still seeds `_hasOlderMessages` and renders the paywall banner
  /// instead of the "Say hello!" empty state.
  bool _providerSeeded = false;
  StreamSubscription<Map<String, dynamic>>? _socketSub;
  // Phase 1f: socket handlers are serialized through this chain so
  // an SKDM's `saveSenderKey` await point can't be preempted by the
  // subsequent group message's `loadSenderKey`. Without this, the
  // group ciphertext that arrived right after its own SKDM could
  // fail to decrypt (null record) and render as an empty bubble.
  // Reassigned on every inbound event — each new event appends to
  // the tail of the chain.
  Future<void> _socketHandlerChain = Future<void>.value();
  PeerIdentityInfo? _peerIdentity;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Nothing to mark-as-read for a draft — there are no messages yet
    // and the conversation doesn't exist on the server.
    if (!_isDraft) {
      _markAsRead();

      // Force a fresh fetch on every entry. Riverpod's autoDispose
      // has a grace period — a quick pop + re-push can re-watch the
      // previous Future before it's disposed, returning stale data
      // from the initial load (missing any messages that arrived via
      // socket while the screen was off-screen, and any sent from
      // the other device). Invalidating here guarantees the next
      // read is a round-trip to the server.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.invalidate(messagesProvider(_convId!));
      });
    }

    // Subscribe to live incoming messages from the socket. Filters
    // to this conversation; decrypts E2EE envelopes the same way
    // the fetch path does (via _decryptMessages on a single-item
    // list). Own-sent messages already land in the list via the
    // send path — we skip any echo that might come back via socket.
    //
    // Events are appended to a serialization chain so an SKDM
    // handler (which persists a sender-key record) always completes
    // before the subsequent group-message handler (which reads that
    // record) begins. Socket events arrive in server-insert order,
    // but without this chain their async await points interleave —
    // the race produced empty bubbles for the first message from a
    // new-to-the-group sender, since the group decrypt ran before
    // the SKDM save finished persisting.
    _socketSub = ref.read(socketServiceProvider).newMessages.listen((data) {
      _socketHandlerChain = _socketHandlerChain
          .then((_) => _onSocketMessage(data))
          .catchError((Object e, StackTrace _) {
        // Swallow per-event failures so one bad message can't
        // freeze the whole chain. The handler itself already logs
        // via debugPrint, so no user-visible surface is needed here.
        debugPrint('[socket] handler error (chain continues): $e');
      });
    });

    // Load any peer-identity change info so we can surface the
    // Phase 1i TOFU banner. Only relevant on direct conversations —
    // group E2EE is Phase 1f.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _refreshPeerIdentityBanner();
    });
  }

  Future<void> _refreshPeerIdentityBanner() async {
    final convId = _convId;
    if (convId == null) return;
    final conv = await ref.read(conversationProvider(convId).future);
    if (!conv.isE2ee || conv.isGroup || conv.otherUserId == null) return;
    final info = await ref
        .read(signalClientProvider)
        .peerIdentityInfo(conv.otherUserId!);
    if (!mounted) return;
    setState(() => _peerIdentity = info);
  }

  Future<void> _dismissIdentityChange() async {
    final convId = _convId;
    if (convId == null) return;
    final conv = ref.read(conversationProvider(convId)).value;
    final peerId = conv?.otherUserId;
    if (peerId == null) return;
    await ref.read(signalClientProvider).dismissIdentityChange(peerId);
    await _refreshPeerIdentityBanner();
  }

  Future<void> _onSocketMessage(Map<String, dynamic> data) async {
    final convId = _convId;
    if (convId == null) return;
    if (data['conversation_id'] != convId) return; // different conv
    final ownId = ref.read(authProvider).user?.id;
    if (ownId == null) return;

    final raw = Message.fromJson(data);
    // Skip if we already have this one (e.g. our own send already
    // inserted it at POST time, or a duplicate socket event).
    if (_messages.any((m) => m.id == raw.id)) return;
    // Skip our own echoes — the send path already inserted with
    // plaintext body, and decrypting an own-E2EE envelope won't work.
    if (raw.senderId == ownId) return;

    final decryptedList = await _decryptMessages(
      [raw],
      ref.read(signalClientProvider),
      ref.read(keyStorageProvider),
      ownId,
    );
    if (!mounted || decryptedList.isEmpty) return;
    setState(() {
      _messages.insert(0, decryptedList.first);
    });
  }

  @override
  void dispose() {
    _socketSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _markAsRead() async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.markAsRead(_convId!);
      // Refresh the conversations list so the unread-dot badge on
      // the Messages bottom-nav icon clears (and the row in the list
      // loses its bold/blue treatment) as soon as we've successfully
      // told the server we've seen this convo.
      if (mounted) ref.invalidate(conversationsProvider);
    } catch (_) {}
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_loadingMore &&
        _hasMore) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_beforeCursor == null || !_hasMore || _loadingMore) return;

    setState(() => _loadingMore = true);
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.getMessages(
        _convId!,
        before: _beforeCursor,
      ) as Map<String, dynamic>;
      final list = (data['messages'] as List<dynamic>?) ?? [];
      final raw =
          list.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
      // Same decryption pass as the initial-load provider.
      final ownId = ref.read(authProvider).user?.id;
      final newMessages = ownId == null
          ? raw
          : await _decryptMessages(
              raw,
              ref.read(signalClientProvider),
              ref.read(keyStorageProvider),
              ownId,
            );

      setState(() {
        _messages.addAll(newMessages);
        // Cursor must be a timestamp — server expects $2::timestamptz.
        _beforeCursor = newMessages.isNotEmpty
            ? newMessages.last.createdAt.toUtc().toIso8601String()
            : null;
        _hasMore = newMessages.length >= 20;
        _loadingMore = false;
      });
    } catch (_) {
      setState(() => _loadingMore = false);
    }
  }

  Future<Map<String, dynamic>> _fetchKeyBundle(String peerUserId) async {
    final api = ref.read(apiServiceProvider);
    return api.getUserKeyBundle(peerUserId);
  }

  Future<StartSessionOutcome?> _ensurePeerSession(
    SignalClient signal,
    String ownId,
    String peerId,
  ) async {
    final outcome = await signal.ensureSessionWithPeer(ownId, peerId, () async {
      final bundleJson = await _fetchKeyBundle(peerId);
      return PeerKeyBundle.fromServerJson(bundleJson);
    });
    if (outcome?.identityChanged == true) {
      await _refreshPeerIdentityBanner();
    }
    return outcome;
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    _messageController.clear();

    try {
      final api = ref.read(apiServiceProvider);

      // Materialize the draft on the server if this is still a draft.
      // We do this lazily — the group row only exists once the first
      // message is committed — so abandoned drafts leave no trace in
      // the DB and the "don't show conversations with no messages"
      // product rule stays enforceable purely by the server query.
      String? convId = _convId;
      if (_isDraft) {
        final draft = widget.draft!;
        final groupData = await api.createGroupConversation(
          memberIds: draft.members.map((m) => m.id).toList(),
          name: draft.name,
        );
        final conv = Conversation.fromJson(groupData as Map<String, dynamic>);
        convId = conv.id;
        // Record the materialized id so subsequent sends / provider
        // watches / invalidations all point at the real row.
        setState(() => _materializedId = conv.id);
      }

      // Branch on conversation.is_e2ee × type. Three paths:
      //   direct + E2EE → 1:1 Double Ratchet (Phase 1e).
      //   group  + E2EE → Sender Keys with SKDM distribution (Phase 1f).
      //   anything else → legacy plaintext.
      //
      // `await` the provider future rather than using valueOrNull —
      // if the user taps send before the provider resolves, a null
      // conv would silently fall through to the plaintext path and
      // get 400'd by the server on an E2EE conversation.
      final conv = await ref.read(conversationProvider(convId!).future);

      Message message;
      if (conv.isE2ee && conv.type == 'direct') {
        final ownId = ref.read(authProvider).user!.id;
        final peerId = conv.otherUserId!;
        final signal = ref.read(signalClientProvider);

        // First message to this peer: fetch their bundle and build a
        // session. The server atomically consumes one OTPK + one
        // Kyber prekey on the fetch, so this is one-shot.
        await _ensurePeerSession(signal, ownId, peerId);

        // Wrap the plaintext in the versioned JSON envelope so the
        // recipient can distinguish text vs image payloads. Pre-
        // Phase-1g messages were raw UTF-8; the decode helper falls
        // back to that for old rows.
        final envelope = encodeTextEnvelope(text);
        final encrypted =
            await signal.encryptMessageFor(ownId, peerId, envelope);

        final data = await api.sendMessage(
          convId,
          ciphertextBase64: base64.encode(encrypted.ciphertext),
          envelopeType: 'signal_1to1',
          protocolVersion: encrypted.messageType,
        );
        // Stash the plaintext envelope on the local Message so the
        // UI renders it immediately, AND persist it keyed by the
        // server-assigned message id. On a later re-fetch we re-
        // hydrate from storage (Double Ratchet is one-way; we can't
        // decrypt our own outgoing envelope after the fact).
        final raw = Message.fromJson(data as Map<String, dynamic>);
        final envelopeText = utf8.decode(envelope);
        await ref.read(keyStorageProvider).savePlaintext(raw.id, envelopeText);
        message = _applyEnvelope(raw, envelopeText);
      } else if (conv.isE2ee && conv.type == 'group') {
        final envelope = encodeTextEnvelope(text);
        final raw = await _sendGroupE2eeEnvelope(
          convId: convId,
          envelope: envelope,
        );
        final envelopeText = utf8.decode(envelope);
        await ref.read(keyStorageProvider).savePlaintext(raw.id, envelopeText);
        message = _applyEnvelope(raw, envelopeText);
      } else {
        final data = await api.sendMessage(convId, body: text);
        message = Message.fromJson(data as Map<String, dynamic>);
      }
      setState(() {
        _messages.insert(0, message);
        _sending = false;
      });

      // After a successful first send out of draft mode, nudge the
      // conversations list to refetch — the new group will now pass
      // the `last_message_at IS NOT NULL` filter and appear at the
      // top when the user navigates back.
      if (widget.draft != null) {
        ref.invalidate(conversationsProvider);
      }
    } catch (e, st) {
      debugPrint('[send] failed: $e\n$st');
      setState(() => _sending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Send failed: $e'),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  /// Phase 1f: sends an arbitrary encoded envelope (text or image)
  /// as an E2EE group message. Handles first-send SKDM distribution
  /// — if we don't yet have a sender-key chain for this group,
  /// generate one, 1:1-encrypt the resulting SKDM to every OTHER
  /// member, then group-encrypt the envelope and POST it.
  ///
  /// Pairwise 1:1 sessions are established as-needed by fetching
  /// each member's key bundle; a user creating a 10-person E2EE
  /// group incurs up to 9 keybundle fetches on their first send.
  ///
  /// Returns the server Message row (fresh id, created_at). Caller
  /// is responsible for caching the plaintext envelope via
  /// KeyStorage.savePlaintext and inserting the applied Message
  /// into `_messages` — keeps this helper agnostic to payload type.
  Future<Message> _sendGroupE2eeEnvelope({
    required String convId,
    required Uint8List envelope,
  }) async {
    final ownId = ref.read(authProvider).user!.id;
    final signal = ref.read(signalClientProvider);
    final api = ref.read(apiServiceProvider);
    final currentConv =
        Conversation.fromJson(await api.getConversationById(convId));
    if (!currentConv.isE2ee || currentConv.type != 'group') {
      throw StateError('conversation is no longer an E2EE group');
    }

    // Step 1: make sure we have a sender-key chain AT THE CURRENT
    // CONVERSATION EPOCH. ensureOwnGroupSenderKey handles three
    // cases: (1) no record yet → generate, return SKDM. (2) record
    // matches epoch → null. (3) record is stale (membership changed
    // server-side and epoch bumped) → rotate, return fresh SKDM.
    //
    // Passing `conv.epoch` forces a rotation on add-member and
    // remove-member without any extra state tracking on the caller
    // side — the server owns the "what's the current membership
    // generation" truth.
    final skdm = await signal.ensureOwnGroupSenderKey(
      ownUserId: ownId,
      conversationId: convId,
      currentEpoch: currentConv.epoch,
    );

    // Step 2: distribute the SKDM if we just generated one.
    if (skdm != null) {
      final members = currentConv.members ?? const <User>[];
      if (members.isEmpty) {
        // Defensive — /conversations/:id should always return the
        // member list for a group, but don't proceed silently if
        // something went wrong upstream. Better to surface than to
        // send a group ciphertext nobody can decrypt.
        throw StateError(
          'group has no members in conv response; cannot distribute SKDM',
        );
      }
      for (final m in members) {
        if (m.id == ownId) continue;

        // Ensure a 1:1 session with this member. If we've never
        // messaged them directly, this pays one keybundle fetch.
        await _ensurePeerSession(signal, ownId, m.id);

        final skdmEnvelope = encodeGroupSkdmEnvelope(
          groupConversationId: convId,
          skdmBytes: skdm,
        );
        final encrypted = await signal.encryptMessageFor(
          ownId,
          m.id,
          skdmEnvelope,
        );
        await api.sendMessage(
          convId,
          ciphertextBase64: base64.encode(encrypted.ciphertext),
          envelopeType: 'signal_skdm',
          protocolVersion: encrypted.messageType,
          recipientId: m.id,
        );
      }
    }

    // Step 3: group-encrypt the envelope under our sender-key chain.
    final ciphertext = await signal.encryptGroupMessage(
      ownUserId: ownId,
      conversationId: convId,
      plaintext: envelope,
    );

    // Step 4: POST as signal_group. protocol_version is set to 1 as
    // a placeholder — Sender Key messages don't have the PKM/Whisper
    // split that 1:1 does, but the server's schema requires *some*
    // value and future protocol revisions may use this field.
    final data = await api.sendMessage(
      convId,
      ciphertextBase64: base64.encode(ciphertext),
      envelopeType: 'signal_group',
      protocolVersion: 1,
      conversationEpoch: currentConv.epoch,
    );
    return Message.fromJson(data as Map<String, dynamic>);
  }

  /// Phase 1g + 1f: E2EE image send. Works for direct (Double
  /// Ratchet) and group (Sender Keys) conversations — the attachment
  /// blob encryption is identical either way (fresh ChaCha20-Poly1305
  /// file key + private-bucket PUT); only the envelope wrapping that
  /// carries the file key + blob reference differs. Dispatches to
  /// `_sendGroupE2eeEnvelope` for groups, inlines Double Ratchet
  /// encrypt for directs.
  Future<void> _sendImageAttachment() async {
    if (_sending) return;
    final convId = _convId;
    if (convId == null) return;

    final conv = ref.read(conversationProvider(convId)).value;
    if (conv == null || !conv.isE2ee) {
      return; // legacy plaintext conversations don't get the button
    }
    final ownId = ref.read(authProvider).user?.id;
    if (ownId == null) return;
    final isGroup = conv.type == 'group';
    final peerId = conv.otherUserId;
    if (!isGroup && peerId == null) return;

    // Dismiss the keyboard *before* the picker presents. On iPad this
    // noticeably reduces the "content-behind-picker flicker": without
    // it, the text field's resignFirstResponder animation runs at the
    // same time the photos sheet animates in, so the message list
    // resizes underneath the incoming modal. Unfocusing first lets
    // the keyboard animate away cleanly, and only the picker's
    // presentation animation plays when it opens.
    FocusManager.instance.primaryFocus?.unfocus();

    // Make sure the Rust dylib is loaded. _sendImageAttachment is
    // the only path that calls rust_aead functions directly without
    // first going through SignalClient (which handles init itself),
    // so if this tap is the first Rust-using action in the app's
    // lifetime, we'd otherwise throw "flutter_rust_bridge has not
    // been initialized". Idempotent — SignalClient.initialize
    // tolerates being called twice.
    final signal = ref.read(signalClientProvider);
    await signal.initialize();

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80, // light compression to bound blob size
      maxWidth: 2400,
      maxHeight: 2400,
    );
    if (picked == null) return;

    setState(() => _sending = true);
    try {
      final imageBytes = await picked.readAsBytes();
      final mime = _mimeForPath(picked.path);

      // Encrypt bytes locally with a fresh per-attachment AEAD key.
      final fileKey = rust_aead.generateFileKey();
      final ciphertext = rust_aead.encryptAttachment(
        fileKey: fileKey,
        plaintext: imageBytes,
      );

      final api = ref.read(apiServiceProvider);

      // Get upload URL + blob key, PUT ciphertext bytes.
      final uploadInfo = await api.getDMAttachmentUploadUrl(mime);
      final key = uploadInfo['key'] as String;
      final uploadUrl = uploadInfo['upload_url'] as String;
      await api.uploadBytes(uploadUrl, ciphertext, mime);

      final attachmentRef = AttachmentRef(
        key: key,
        fileKey: fileKey,
        mime: mime,
      );
      final envelope = encodeImageEnvelope(attachmentRef);

      Message raw;
      if (isGroup) {
        // Group E2EE image: reuse the same helper that sends text
        // group messages. It handles sender-key chain creation +
        // SKDM distribution to any members we haven't sent to yet.
        raw = await _sendGroupE2eeEnvelope(
          convId: convId,
          envelope: envelope,
        );
      } else {
        // Direct E2EE image — 1:1 Double Ratchet path.
        await _ensurePeerSession(signal, ownId, peerId!);

        final encrypted =
            await signal.encryptMessageFor(ownId, peerId, envelope);
        final data = await api.sendMessage(
          convId,
          ciphertextBase64: base64.encode(encrypted.ciphertext),
          envelopeType: 'signal_1to1',
          protocolVersion: encrypted.messageType,
        );
        raw = Message.fromJson(data as Map<String, dynamic>);
      }

      final envelopeText = utf8.decode(envelope);
      await ref.read(keyStorageProvider).savePlaintext(raw.id, envelopeText);

      // Local Message already has the bytes we just encrypted —
      // show them immediately rather than round-tripping a
      // download + decrypt.
      final local = _applyEnvelope(raw, envelopeText).withAttachmentBytes(
        imageBytes,
      );
      setState(() {
        _messages.insert(0, local);
        _sending = false;
      });
    } catch (e, st) {
      debugPrint('[send-image] failed: $e\n$st');
      setState(() => _sending = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image send failed: $e')),
        );
      }
    }
  }

  /// Whether the current conversation is an E2EE thread — gates the
  /// attach button. Phase 1g shipped direct E2EE attachments; Phase
  /// 1f extended the same path to groups via Sender Keys. Legacy
  /// plaintext conversations hide the button because image send is
  /// E2EE-only (the `dm-attachments` bucket is private + presigned).
  bool _isE2ee() {
    final convId = _convId;
    if (convId == null) return false;
    final conv = ref.read(conversationProvider(convId)).value;
    return conv != null && conv.isE2ee;
  }

  String _mimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
    return 'image/jpeg';
  }

  String _formatTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    final hour = local.hour;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour == 0
        ? 12
        : hour > 12
            ? hour - 12
            : hour;
    return '$displayHour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    // Draft mode: no server row yet. Render the AppBar from the draft
    // and show an empty message area — no provider watches (they'd
    // 404 against a nonexistent conversation id). The `_sendMessage`
    // path materializes on first send, which flips us out of draft
    // mode and lets the normal rendering path take over.
    if (_isDraft) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              } else {
                context.go('/messages');
              }
            },
          ),
          titleSpacing: 0,
          title: _buildDraftTitle(widget.draft!),
        ),
        body: Column(
          children: [
            const Expanded(
              child: EmptyState(
                icon: Icons.chat_bubble_outline_rounded,
                title: 'No messages yet',
                subtitle: 'Say hello!',
              ),
            ),
            _buildInputBar(colors, theme),
          ],
        ),
      );
    }

    final convId = _convId!;
    final convo = ref.watch(conversationProvider(convId));
    final initialMessages = ref.watch(messagesProvider(convId));

    // Reactively re-sync _messages whenever the provider yields a
    // new snapshot — including after invalidate-forced refetches on
    // re-entry. Replaces an older "seed once" pattern that couldn't
    // absorb later updates (so re-entering a conversation after
    // messages arrived via socket would show the stale initial
    // load). Provider is the source of truth; local optimistic
    // inserts from send + socket arrivals are also in the server's
    // fresh response, so a full replace is safe.
    ref.listen<AsyncValue<MessagesResult>>(
      messagesProvider(convId),
      (_, next) {
        next.whenData((result) {
          if (!mounted) return;
          setState(() {
            _messages
              ..clear()
              ..addAll(result.messages);
            _beforeCursor = result.messages.isNotEmpty
                ? result.messages.last.createdAt.toUtc().toIso8601String()
                : null;
            _hasMore = result.messages.length >= 20;
            _hasOlderMessages = result.hasOlderMessages;
            _providerSeeded = true;
          });
        });
      },
    );

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              context.go('/messages');
            }
          },
        ),
        titleSpacing: 0,
        title: convo.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const Text('Chat'),
          data: (c) => _buildTitle(c),
        ),
      ),
      body: Column(
        children: [
          if (_peerIdentity?.showChangeBanner ?? false)
            _IdentityChangeBanner(
              displayName: convo.value?.otherDisplayName ?? 'This person',
              onDismiss: _dismissIdentityChange,
            ),
          Expanded(
            child: initialMessages.when(
              loading: () => const LoadingIndicator(),
              error: (e, _) => ErrorView(
                message: 'Failed to load messages',
                onRetry: () => ref.invalidate(messagesProvider(convId)),
              ),
              data: (result) {
                final loaded = result.messages;
                // Seed _messages + flags from the provider exactly once,
                // regardless of whether the payload was empty. Previously
                // the seed required `loaded.isNotEmpty`, which meant a
                // conversation whose entire history sits behind the Free
                // 7-day gate fell through to "No messages yet / Say
                // hello!" with no hint that older content existed. That
                // was the iPad-cross-device bug report.
                if (_messages.isEmpty && !_providerSeeded) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted || _providerSeeded) return;
                    setState(() {
                      _providerSeeded = true;
                      if (loaded.isNotEmpty) {
                        _messages.addAll(loaded);
                        _beforeCursor =
                            loaded.last.createdAt.toUtc().toIso8601String();
                        _hasMore = loaded.length >= 20;
                      }
                      _hasOlderMessages = result.hasOlderMessages;
                    });
                  });
                  if (loaded.isNotEmpty) {
                    return _buildMessageList(loaded, colors, theme);
                  }
                  // Intentionally fall through to the empty-state block
                  // below so the paywall banner can render in place of
                  // "Say hello!" when older messages exist but are gated.
                }

                if (_messages.isEmpty) {
                  final isFree = !AppLimits.isPaid(
                    ref.read(authProvider).user?.subscriptionStatus,
                  );
                  if (result.hasOlderMessages && isFree) {
                    // History exists but is plan-gated. Show the
                    // upgrade prompt instead of the default empty
                    // state — matches what _buildMessageList does for
                    // the top-of-list case when there ARE recent
                    // messages. PaywallBanner handles its own padding.
                    return const Center(child: PaywallBanner());
                  }
                  return const EmptyState(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: 'No messages yet',
                    subtitle: 'Say hello!',
                  );
                }

                return _buildMessageList(_messages, colors, theme);
              },
            ),
          ),
          _buildInputBar(colors, theme),
        ],
      ),
    );
  }

  /// AppBar title row. Direct conversations show a single avatar and
  /// the other user's display name. Group conversations show stacked
  /// member avatars (2 of the non-self members for visual variety) and
  /// the group name, and the whole row is tappable to open the group
  /// info sheet.
  Widget _buildTitle(Conversation c) {
    if (!c.isGroup) {
      return Row(
        children: [
          Avatar(
            imageUrl: c.otherAvatarUrl,
            displayName: c.otherDisplayName ?? '?',
            size: 32,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              c.otherDisplayName ?? 'Chat',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (c.isE2ee) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'End-to-end encrypted',
              child: Icon(
                Icons.lock_rounded,
                size: 14,
                color: AppColors.of(context).textTertiary,
              ),
            ),
          ],
        ],
      );
    }

    final currentUserId = ref.read(authProvider).user?.id;
    final others =
        (c.members ?? []).where((m) => m.id != currentUserId).toList();
    return InkWell(
      onTap: () => _showGroupInfoSheet(c),
      child: Row(
        children: [
          StackedAvatars(
            members: others,
            groupName: c.name ?? '?',
            size: 32,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  c.name ?? 'Group',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${(c.members ?? []).length} members',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.of(context).textTertiary,
                        fontSize: 11,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// AppBar title for a draft group (not yet persisted). Member count
  /// and avatars come from the DraftGroup's in-memory member list —
  /// no server call. The "+ 1" on member count accounts for the
  /// current user, who isn't in draft.members but will be on the
  /// server after materialization.
  Widget _buildDraftTitle(DraftGroup draft) {
    return Row(
      children: [
        StackedAvatars(
          members: draft.members,
          groupName: draft.name,
          size: 32,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                draft.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                '${draft.members.length + 1} members',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.of(context).textTertiary,
                      fontSize: 11,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Group info sheet: member list + creator actions (rename, add
  /// members, remove members) + leave. Non-creators see member list +
  /// leave only.
  void _showGroupInfoSheet(Conversation c) {
    final currentUserId = ref.read(authProvider).user?.id;
    final isCreator = c.isCreator(currentUserId ?? '');
    final members = c.members ?? [];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        final theme = Theme.of(ctx);
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) => Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textTertiary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.name ?? 'Group',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    if (isCreator)
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showRenameDialog(c);
                        },
                      ),
                  ],
                ),
              ),
              Divider(height: 0.5, thickness: 0.5, color: colors.border),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    // Member header with member count + creator-only
                    // "Add members" action.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          Text(
                            'Members (${members.length})',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: colors.textSecondary,
                            ),
                          ),
                          const Spacer(),
                          if (isCreator)
                            TextButton.icon(
                              icon: const Icon(Icons.person_add_outlined,
                                  size: 16),
                              label: const Text('Add'),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _showAddMembersSheet(c);
                              },
                            ),
                        ],
                      ),
                    ),
                    ...members.map((m) {
                      final isSelf = m.id == currentUserId;
                      return ListTile(
                        leading: Avatar(
                          imageUrl: m.avatarUrl,
                          displayName: m.displayName,
                          size: 40,
                        ),
                        title: Text(m.displayName),
                        subtitle: c.createdBy == m.id
                            ? Text(
                                'Creator',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.textTertiary,
                                ),
                              )
                            : null,
                        // Creator can remove anyone except themselves.
                        // Non-creators have no per-member action.
                        trailing: (isCreator && !isSelf)
                            ? IconButton(
                                icon: Icon(
                                  Icons.remove_circle_outline,
                                  color: AppColors.error,
                                ),
                                onPressed: () => _confirmRemove(ctx, c, m),
                              )
                            : null,
                      );
                    }),
                    const Divider(height: 24),
                    ListTile(
                      leading: Icon(
                        Icons.logout_rounded,
                        color: AppColors.error,
                      ),
                      title: Text(
                        'Leave group',
                        style: TextStyle(color: AppColors.error),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _confirmLeave(c);
                      },
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showRenameDialog(Conversation c) async {
    final controller = TextEditingController(text: c.name ?? '');
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(hintText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null || !mounted) return;

    try {
      final api = ref.read(apiServiceProvider);
      await api.renameConversation(_convId!, newName);
      ref.invalidate(conversationProvider(_convId!));
      ref.invalidate(conversationsProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to rename: $e')),
      );
    }
  }

  Future<void> _showAddMembersSheet(Conversation c) async {
    final api = ref.read(apiServiceProvider);
    List<User> mutualFollows;
    try {
      final data = await api.getMutualFollows();
      mutualFollows = (data as List)
          .map((e) => User.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to load contacts')),
      );
      return;
    }
    if (!mounted) return;

    final currentMemberIds = (c.members ?? []).map((m) => m.id).toSet();
    final eligible =
        mutualFollows.where((u) => !currentMemberIds.contains(u.id)).toList();
    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No eligible mutuals to add')),
      );
      return;
    }

    final selected = <String>{};
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final theme = Theme.of(ctx);
            // Remaining capacity (creator + current + new ≤ 10).
            final remaining = 10 - currentMemberIds.length;
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (ctx, scrollController) => Column(
                children: [
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Text('Add members', style: theme.textTheme.titleLarge),
                        const Spacer(),
                        TextButton(
                          onPressed: selected.isEmpty
                              ? null
                              : () async {
                                  Navigator.pop(ctx);
                                  try {
                                    await api.addConversationMembers(
                                      _convId!,
                                      selected.toList(),
                                    );
                                    ref.invalidate(
                                        conversationProvider(_convId!));
                                    ref.invalidate(conversationsProvider);
                                  } catch (e) {
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Failed to add: $e'),
                                      ),
                                    );
                                  }
                                },
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: eligible.length,
                      itemBuilder: (ctx, i) {
                        final u = eligible[i];
                        final isSelected = selected.contains(u.id);
                        final atCap = selected.length >= remaining;
                        final enabled = isSelected || !atCap;
                        return CheckboxListTile(
                          value: isSelected,
                          enabled: enabled,
                          onChanged: (v) {
                            setSheetState(() {
                              if (v == true) {
                                selected.add(u.id);
                              } else {
                                selected.remove(u.id);
                              }
                            });
                          },
                          secondary: Avatar(
                            imageUrl: u.avatarUrl,
                            displayName: u.displayName,
                            size: 40,
                          ),
                          title: Text(u.displayName),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmRemove(
      BuildContext sheetContext, Conversation c, User member) async {
    final confirmed = await showDialog<bool>(
      context: sheetContext,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${member.displayName}?'),
        content: const Text('They will no longer see this group.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Remove',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!sheetContext.mounted) return;

    try {
      final api = ref.read(apiServiceProvider);
      final sheetNavigator = Navigator.of(sheetContext);
      await api.removeConversationMember(_convId!, member.id);
      ref.invalidate(conversationProvider(_convId!));
      ref.invalidate(conversationsProvider);
      if (mounted) sheetNavigator.maybePop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove: $e')),
      );
    }
  }

  Future<void> _confirmLeave(Conversation c) async {
    final currentUserId = ref.read(authProvider).user?.id;
    final others =
        (c.members ?? []).where((m) => m.id != currentUserId).toList();
    final isCreator = c.isCreator(currentUserId ?? '');

    // Creator with other members still present: must pick a successor.
    // Sole-creator and non-creator cases fall through to the confirm
    // dialog (server handles both without new_admin_id).
    User? newAdmin;
    if (isCreator && others.isNotEmpty) {
      newAdmin = await _pickNewAdmin(others);
      if (newAdmin == null) return; // cancelled
      if (!mounted) return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final String title;
        final String body;
        if (others.isEmpty) {
          title = 'Leave and delete group?';
          body =
              "You're the only member. Leaving will permanently delete this group and all its messages.";
        } else if (newAdmin != null) {
          title = 'Transfer admin and leave?';
          body =
              "${newAdmin.displayName} will become the new admin. You won't receive new messages.";
        } else {
          title = 'Leave this group?';
          body = "You won't receive new messages.";
        }
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Leave', style: TextStyle(color: AppColors.error)),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    try {
      final api = ref.read(apiServiceProvider);
      await api.leaveConversation(
        _convId!,
        newAdminId: newAdmin?.id,
      );
      ref.invalidate(conversationsProvider);
      if (mounted) context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to leave: $e')),
      );
    }
  }

  /// Picks a current member to become the new admin. Returns null if
  /// the user dismisses the sheet without choosing.
  Future<User?> _pickNewAdmin(List<User> others) async {
    return showModalBottomSheet<User>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final colors = AppColors.of(ctx);
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) => Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textTertiary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  'Choose new admin',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  "You're the admin. Pick a member to take over before you leave.",
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
              Divider(height: 0.5, thickness: 0.5, color: colors.border),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: others.length,
                  itemBuilder: (ctx, i) {
                    final u = others[i];
                    return ListTile(
                      leading: Avatar(
                        imageUrl: u.avatarUrl,
                        displayName: u.displayName,
                        size: 44,
                      ),
                      title: Text(u.displayName),
                      onTap: () => Navigator.pop(ctx, u),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessageList(
    List<Message> messages,
    AppColorTokens colors,
    ThemeData theme,
  ) {
    final currentUserId = ref.read(authProvider).user?.id;
    final isFree = !AppLimits.isPaid(
      ref.read(authProvider).user?.subscriptionStatus,
    );
    final showBanner = _hasOlderMessages && isFree && !_hasMore;
    final extraItems = (_loadingMore ? 1 : 0) + (showBanner ? 1 : 0);
    final isGroup =
        ref.read(conversationProvider(_convId!)).value?.isGroup ?? false;

    // RepaintBoundary isolates the message area's paint layer so
    // transient MediaQuery / safe-area changes during iPad modal
    // presentations (image picker form-sheet, share sheet, etc.) can't
    // force the whole bubble list to repaint behind the modal. On
    // iPhone the picker covers the screen so this is invisible either
    // way; on iPad it reduces the content-behind-modal flicker the
    // user reported when tapping the attach icon.
    return RepaintBoundary(
      child: ListView.builder(
        controller: _scrollController,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: messages.length + extraItems,
        itemBuilder: (context, index) {
          // Loading indicator at the very end (oldest)
          if (_loadingMore && index == messages.length + extraItems - 1) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: LoadingIndicator(),
            );
          }

          // Paywall banner after all messages (at the "top" visually)
          if (showBanner && index == messages.length) {
            return const PaywallBanner();
          }

          final message = messages[index];
          final isOwn = message.senderId == currentUserId;

          // In groups, show the sender's display name above their bubble
          // (unless it matches the previous message — keeps consecutive
          // messages from the same sender visually grouped).
          // `messages` is reversed (newest first), so the "previous" in
          // reading order is actually the next index up.
          final priorSenderId = (index + 1 < messages.length)
              ? messages[index + 1].senderId
              : null;
          final showSenderLabel =
              isGroup && !isOwn && message.senderId != priorSenderId;

          return _MessageBubble(
            // Key by message id so the ListView doesn't recycle the State
            // of nested stateful children (most importantly
            // `_EncryptedImageBubble`, which holds decrypted bytes) when
            // a new message is inserted and everything shifts by one
            // position. Without this key, the image bubble at a given
            // index keeps the previously-decrypted bytes after the insert
            // because `widget.attachment` changes but `initState` doesn't
            // rerun. Classic Flutter-state-recycling bug — see fix notes.
            key: ValueKey(message.id),
            message: message,
            isOwn: isOwn,
            colors: colors,
            theme: theme,
            timeLabel: _formatTime(message.createdAt),
            showSenderLabel: showSenderLabel,
          );
        },
      ),
    );
  }

  Widget _buildInputBar(AppColorTokens colors, ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        border: Border(
          top: BorderSide(
            color: colors.border,
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // Attach button — only on direct E2EE conversations for
              // now (Phase 1g). Hidden on legacy + group until
              // Sender Keys + legacy-thread policy are decided.
              if (_isE2ee()) ...[
                SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    onPressed: _sending ? null : _sendImageAttachment,
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.image_outlined,
                      color: colors.textSecondary,
                      size: 22,
                    ),
                    tooltip: 'Send encrypted photo',
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: TextField(
                  controller: _messageController,
                  textInputAction: TextInputAction.send,
                  textCapitalization: TextCapitalization.sentences,
                  minLines: 1,
                  maxLines: 4,
                  onSubmitted: (_) => _sendMessage(),
                  decoration: InputDecoration(
                    hintText: 'Message',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    filled: true,
                    fillColor: colors.card,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: colors.border,
                        width: 0.5,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: colors.border,
                        width: 0.5,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: colors.textTertiary,
                        width: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
              SpeechInputButton(controller: _messageController),
              const SizedBox(width: 4),
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  onPressed: _sending ? null : _sendMessage,
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.arrow_upward_rounded,
                    color: colors.textPrimary,
                    size: 20,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: colors.textPrimary.withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.isOwn,
    required this.colors,
    required this.theme,
    required this.timeLabel,
    this.showSenderLabel = false,
  });

  final Message message;
  final bool isOwn;
  final AppColorTokens colors;
  final ThemeData theme;
  final String timeLabel;

  /// In group DMs, set this true for the first message in a run by a
  /// non-self sender so the display name appears above the bubble.
  /// Suppressed for own messages and for direct DMs.
  final bool showSenderLabel;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final maxBubbleWidth = screenWidth * 0.75;

    final bubbleRadius = isOwn
        ? const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(14),
            bottomRight: Radius.circular(2),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(14),
            topRight: Radius.circular(14),
            bottomLeft: Radius.circular(2),
            bottomRight: Radius.circular(14),
          );

    // Both bubbles use the dedicated `bubbleOwn` / `bubbleOther` tokens
    // (defined in app_colors.dart) — soft greys that sit gently above
    // the surface in both themes. Previously own bubbles used
    // `textPrimary` (pure white in dark, near-black in light) which
    // produced an aggressive contrast slap. Text stays at `textPrimary`
    // for both sides so it reads against either bubble shade.
    final bubbleColor = isOwn ? colors.bubbleOwn : colors.bubbleOther;
    final textColor = colors.textPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment:
            isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showSenderLabel)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                message.senderDisplayName,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          Container(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: bubbleRadius,
              border: isOwn
                  ? null
                  : Border.all(
                      color: colors.border,
                      width: 0.5,
                    ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.attachment != null) ...[
                  _EncryptedImageBubble(
                    // Belt-and-suspenders alongside the outer
                    // `_MessageBubble` key: also key the image bubble by
                    // message id so even a ListView without the outer
                    // key wouldn't recycle this widget's State across
                    // different messages.
                    key: ValueKey('img-${message.id}'),
                    attachment: message.attachment!,
                    messageId: message.id,
                    hasCaption:
                        message.body != null && message.body!.isNotEmpty,
                    isOwn: isOwn,
                    colors: colors,
                  ),
                ],
                if (message.mediaUrl != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(14),
                      topRight: const Radius.circular(14),
                      bottomLeft: message.body != null
                          ? Radius.zero
                          : isOwn
                              ? const Radius.circular(14)
                              : const Radius.circular(2),
                      bottomRight: message.body != null
                          ? Radius.zero
                          : isOwn
                              ? const Radius.circular(2)
                              : const Radius.circular(14),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 250),
                      child: CachedNetworkImage(
                        imageUrl: message.mediaUrl!,
                        fit: BoxFit.cover,
                        cacheManager: AppImageCacheManager.instance,
                        memCacheWidth:
                            (250 * MediaQuery.devicePixelRatioOf(context))
                                .round(),
                        fadeInDuration: const Duration(milliseconds: 150),
                        placeholder: (context, url) => Container(
                          height: 150,
                          color: colors.surfaceAlt,
                          child: const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          height: 150,
                          color: colors.surfaceAlt,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: colors.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (message.body != null && message.body!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: LinkifiedText(
                      text: message.body!,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: textColor,
                      ),
                      linkStyle: theme.textTheme.bodyLarge?.copyWith(
                        color:
                            isOwn ? Colors.white.withValues(alpha: 0.9) : null,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              timeLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textTertiary,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Phase 1i TOFU banner. Appears when a peer's identity public key
/// changes from what we had on file (new install, new device — or
/// worse, a server-mounted MITM). Not fatal: user can keep sending,
/// but should verify out-of-band if they weren't expecting it.
class _IdentityChangeBanner extends StatelessWidget {
  const _IdentityChangeBanner({
    required this.displayName,
    required this.onDismiss,
  });

  final String displayName;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // No dedicated "warning" token in AppColorTokens yet; amber is
    // the closest "pay attention but not critical" shade.
    final warn = Colors.amber.shade700;
    return Container(
      color: warn.withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Icon(Icons.shield_moon_outlined, size: 18, color: warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "$displayName's security code changed. This usually means "
              'they reinstalled or got a new phone. If you weren\'t '
              'expecting this, verify before continuing.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textPrimary,
                  ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onDismiss,
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}

/// Phase 1g: renders an E2EE image attachment. If `decryptedBytes`
/// is already present (e.g. the user's own send, or a prior cache
/// hit), renders immediately. Otherwise fetches the ciphertext via
/// a short-TTL presigned GET and decrypts with the file key carried
/// in the message envelope — no round trip for the plaintext.
class _EncryptedImageBubble extends ConsumerStatefulWidget {
  const _EncryptedImageBubble({
    super.key,
    required this.attachment,
    required this.messageId,
    required this.hasCaption,
    required this.isOwn,
    required this.colors,
  });

  final AttachmentRef attachment;
  final String messageId;
  final bool hasCaption;
  final bool isOwn;
  final AppColorTokens colors;

  @override
  ConsumerState<_EncryptedImageBubble> createState() =>
      _EncryptedImageBubbleState();
}

class _EncryptedImageBubbleState extends ConsumerState<_EncryptedImageBubble> {
  Uint8List? _bytes;
  bool _loading = false;
  bool _failed = false;

  // Resolve the initial bytes for this bubble from, in order:
  //   1. AttachmentRef.decryptedBytes — populated only on the local
  //      sender's own-send path (we keep the picked plaintext around
  //      so the sender's bubble never has to round-trip).
  //   2. The app-wide plaintext cache — populated the first time this
  //      blob was decrypted in the current auth session. Survives
  //      scroll-out-of-cacheExtent + navigation away and back.
  // Returns null if the attachment still needs a fetch + decrypt.
  Uint8List? _resolveCachedBytes() {
    final local = widget.attachment.decryptedBytes;
    if (local != null) return local;
    return ref
        .read(attachmentPlaintextCacheProvider)
        .get(widget.attachment.key);
  }

  @override
  void initState() {
    super.initState();
    _bytes = _resolveCachedBytes();
    if (_bytes == null) {
      _fetchAndDecrypt();
    }
  }

  @override
  void didUpdateWidget(_EncryptedImageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If our parent recycles this State for a different message (no
    // ValueKey in the list, or a future refactor that loses the key),
    // `widget.attachment` will change while `_bytes` still holds the
    // previous message's decrypted plaintext. Detect that and reload.
    // Compare on the stable identifiers (message id + blob key) rather
    // than the AttachmentRef instance, since `Message.fromJson` builds
    // fresh refs each refresh even for the same logical attachment.
    if (oldWidget.messageId != widget.messageId ||
        oldWidget.attachment.key != widget.attachment.key) {
      _bytes = _resolveCachedBytes();
      _loading = false;
      _failed = false;
      if (_bytes == null) {
        _fetchAndDecrypt();
      }
    }
  }

  Future<void> _fetchAndDecrypt() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      // In the normal path _decryptMessages has already loaded the
      // Rust dylib (every E2EE message triggers it). Call it anyway
      // so a pathological first-paint-with-only-attachments doesn't
      // throw "flutter_rust_bridge has not been initialized".
      await ref.read(signalClientProvider).initialize();
      // Key is "dm/<uuid>"; the API takes the uuid tail.
      final id = widget.attachment.key.startsWith('dm/')
          ? widget.attachment.key.substring(3)
          : widget.attachment.key;
      final api = ref.read(apiServiceProvider);
      final url = await api.getDMAttachmentDownloadUrl(id);
      final ciphertext = await api.downloadAttachmentCiphertext(url);
      final plaintext = rust_aead.decryptAttachment(
        fileKey: widget.attachment.fileKey,
        ciphertextWithNonce: ciphertext,
      );
      // Populate the app-wide cache before we setState so a sibling
      // bubble that's also about to paint this same blob (extremely
      // unlikely — blob keys are unique per send — but cheap) picks
      // up the hit.
      ref
          .read(attachmentPlaintextCacheProvider)
          .put(widget.attachment.key, plaintext);
      if (!mounted) return;
      setState(() {
        _bytes = plaintext;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[attachment] fetch/decrypt failed: $e');
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(14),
      topRight: const Radius.circular(14),
      bottomLeft: widget.hasCaption
          ? Radius.zero
          : widget.isOwn
              ? const Radius.circular(14)
              : const Radius.circular(2),
      bottomRight: widget.hasCaption
          ? Radius.zero
          : widget.isOwn
              ? const Radius.circular(2)
              : const Radius.circular(14),
    );
    final placeholder = Container(
      constraints: const BoxConstraints(maxWidth: 250, minHeight: 150),
      color: widget.colors.surfaceAlt,
      child: Center(
        child: _failed
            ? Icon(Icons.broken_image_outlined,
                color: widget.colors.textTertiary)
            : const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    );
    return ClipRRect(
      borderRadius: radius,
      child: _bytes != null
          ? ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 250),
              child: Image.memory(
                _bytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            )
          : placeholder,
    );
  }
}
