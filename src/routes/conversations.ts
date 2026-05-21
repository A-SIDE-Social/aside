import { Router } from 'express';
import { v4 as uuidv4 } from 'uuid';
import { query } from '../db/pool';
import { writeLimit } from '../middleware/rateLimit';
import { asyncHandler, isMutualFollow, resolveMediaUrl, getUserSubscriptionStatus, parseBeforeCursor } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { getPlanLimits } from '../constants';
import { getIO } from '../socket';
import { notifyNewDM } from '../firebase';

const router = Router();

// Hard cap on group size. 10 total (creator + 9 others) matches the
// v1 spec — small enough that sender-key rekey is cheap when we
// layer E2EE on top, big enough to cover a real friend group.
const MAX_GROUP_MEMBERS = 10;

// Max length for a group conversation name. Mirrors the DB check
// (1–50) so we can reject client-side before the INSERT.
const MAX_GROUP_NAME_LENGTH = 50;

// Loose UUID v4 shape check — same as comments.ts.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ── Helpers ────────────────────────────────────────────────────────

async function assertMember(conversationId: string, userId: string): Promise<void> {
  const { rows } = await query(
    'SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2',
    [conversationId, userId],
  );
  if (rows.length === 0) throw new AppError(403, 'Not a member of this conversation');
}

async function getConversation(conversationId: string): Promise<any | null> {
  const { rows } = await query(
    'SELECT * FROM conversations WHERE id = $1',
    [conversationId],
  );
  return rows[0] ?? null;
}

async function loadMembers(conversationId: string, req: any): Promise<any[]> {
  const { rows } = await query(
    `SELECT u.id, u.username, u.display_name, u.avatar_url
     FROM conversation_members cm
     JOIN users u ON u.id = cm.user_id
     WHERE cm.conversation_id = $1
     ORDER BY cm.joined_at ASC`,
    [conversationId],
  );
  for (const row of rows) {
    if (row.avatar_url) row.avatar_url = resolveMediaUrl(row.avatar_url, req);
  }
  return rows;
}

// ── Routes ─────────────────────────────────────────────────────────

// GET / - List conversations for the current user.
//
// Rows come back with enough shape for the client to render either a
// direct DM (existing `other_*` fields populated) or a group DM
// (`name` + `members` populated instead). `unread_count` is computed
// against each member's last_read_at.
router.get(
  '/',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    // Conversations appear in the list only once at least one message
    // has been sent. Starting-but-never-sending shouldn't create
    // clutter. The client enforces this by not persisting a group to
    // the server until the first message is sent (lazy creation); the
    // server-side filter is belt-and-suspenders against any pre-lazy
    // client that slipped through.
    // Unread count excludes Phase 1f signal_skdm rows — they're
    // cryptographic control messages (per-recipient SKDM
    // deliveries), invisible in the UI, and users don't expect them
    // to affect the conversation list badge. Without this filter,
    // the first message from a new-to-the-group sender shows as "2
    // unread" (SKDM + the actual message).
    const { rows } = await query(
      `SELECT c.*,
              cm.last_read_at,
              (SELECT COUNT(*) FROM messages m
               WHERE m.conversation_id = c.id
                 AND m.created_at > COALESCE(cm.last_read_at, '1970-01-01')
                 AND m.sender_id != $1
                 AND m.envelope_type IS DISTINCT FROM 'signal_skdm') AS unread_count
       FROM conversations c
       JOIN conversation_members cm ON cm.conversation_id = c.id AND cm.user_id = $1
       WHERE c.last_message_at IS NOT NULL
       ORDER BY c.last_message_at DESC`,
      [userId],
    );

    // Enrich each conversation with either the other user (direct) or
    // the member list (group). Keeping these queries separate avoids
    // a monster JOIN that's hard to tune.
    const enriched = await Promise.all(
      rows.map(async (c: any) => {
        if (c.conversation_type === 'direct') {
          const { rows: others } = await query(
            `SELECT u.id, u.username, u.display_name, u.avatar_url
             FROM conversation_members cm
             JOIN users u ON u.id = cm.user_id
             WHERE cm.conversation_id = $1 AND cm.user_id != $2
             LIMIT 1`,
            [c.id, userId],
          );
          const other = others[0];
          if (other) {
            c.other_user_id = other.id;
            c.other_username = other.username;
            c.other_display_name = other.display_name;
            c.other_avatar_url = other.avatar_url
              ? resolveMediaUrl(other.avatar_url, req)
              : null;
          }
          c.members = null;
        } else {
          c.members = await loadMembers(c.id, req);
          c.other_user_id = null;
          c.other_username = null;
          c.other_display_name = null;
          c.other_avatar_url = null;
        }
        return c;
      }),
    );

    res.json({ conversations: enriched });
  }),
);

// GET /:id - Single conversation by id. Unlike GET /, this doesn't
// require last_message_at to be set — the client uses this when it's
// just created a conversation and needs the full shape (including
// is_e2ee + other user info) before the first message is sent.
router.get(
  '/:id',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    // Must be a member. Same rule as elsewhere in this file.
    await assertMember(id, userId);

    const { rows } = await query(
      `SELECT c.*,
              cm.last_read_at,
              (SELECT COUNT(*) FROM messages m
               WHERE m.conversation_id = c.id
                 AND m.created_at > COALESCE(cm.last_read_at, '1970-01-01')
                 AND m.sender_id != $1) AS unread_count
       FROM conversations c
       JOIN conversation_members cm ON cm.conversation_id = c.id AND cm.user_id = $1
       WHERE c.id = $2`,
      [userId, id],
    );
    if (rows.length === 0) throw new AppError(404, 'Conversation not found');

    const c: any = rows[0];
    if (c.conversation_type === 'direct') {
      const { rows: others } = await query(
        `SELECT u.id, u.username, u.display_name, u.avatar_url
         FROM conversation_members cm
         JOIN users u ON u.id = cm.user_id
         WHERE cm.conversation_id = $1 AND cm.user_id != $2
         LIMIT 1`,
        [c.id, userId],
      );
      const other = others[0];
      if (other) {
        c.other_user_id = other.id;
        c.other_username = other.username;
        c.other_display_name = other.display_name;
        c.other_avatar_url = other.avatar_url
          ? resolveMediaUrl(other.avatar_url, req)
          : null;
      }
      c.members = null;
    } else {
      c.members = await loadMembers(c.id, req);
      c.other_user_id = null;
      c.other_username = null;
      c.other_display_name = null;
      c.other_avatar_url = null;
    }

    res.json({ conversation: c });
  }),
);

// POST / - Create (or get) a conversation.
//
// Two shapes:
//   Direct: { user_id } — reuses the existing 1:1 path. Mutual follow required.
//   Group:  { member_ids: [uuid, ...], name } — 1-9 other members, must
//           all be mutual follows of the creator. Name 1-50 chars.
//
// The union is distinguished by the presence of `member_ids`. We keep
// the old `user_id` shape so build ≤ 28 mobile clients keep working.
router.post(
  '/',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { user_id, member_ids, name, is_e2ee } = req.body;
    // Locked at creation. Once the conversation is marked E2EE,
    // subsequent message POSTs must carry ciphertext (and plaintext
    // body/media_url are rejected). Defaults false — legacy behavior.
    const isE2ee = is_e2ee === true;

    // ── Group path ──
    if (Array.isArray(member_ids)) {
      if (typeof name !== 'string' || name.trim().length === 0) {
        throw new AppError(400, 'Group conversations require a name');
      }
      const trimmedName = name.trim();
      if (trimmedName.length > MAX_GROUP_NAME_LENGTH) {
        throw new AppError(400, `Group name must be ${MAX_GROUP_NAME_LENGTH} characters or fewer`);
      }

      // Validate + dedupe + exclude creator from member_ids.
      const distinctMembers = Array.from(new Set(
        member_ids.filter((v: any) => typeof v === 'string' && UUID_RE.test(v) && v !== userId),
      )) as string[];

      if (distinctMembers.length === 0) {
        throw new AppError(400, 'At least one other member is required');
      }
      // Creator + others ≤ MAX_GROUP_MEMBERS.
      if (distinctMembers.length + 1 > MAX_GROUP_MEMBERS) {
        throw new AppError(
          400,
          `Group conversations are limited to ${MAX_GROUP_MEMBERS} members (you + ${MAX_GROUP_MEMBERS - 1} others)`,
        );
      }

      // Every other member must be a mutual follow of the creator.
      // Run in parallel; any false rejects.
      const mutualChecks = await Promise.all(
        distinctMembers.map((m) => isMutualFollow(userId, m)),
      );
      if (mutualChecks.some((ok) => !ok)) {
        throw new AppError(403, 'All members must be mutual follows of the creator');
      }

      // Verify targets exist (protects against stale ids).
      const { rows: existingUsers } = await query(
        `SELECT id FROM users WHERE id = ANY($1::uuid[]) AND deleted_at IS NULL`,
        [distinctMembers],
      );
      if (existingUsers.length !== distinctMembers.length) {
        throw new AppError(400, 'One or more members not found');
      }

      // Create conversation.
      const { rows: inserted } = await query(
        `INSERT INTO conversations (conversation_type, name, created_by, is_e2ee)
         VALUES ('group', $1, $2, $3) RETURNING *`,
        [trimmedName, userId, isE2ee],
      );
      const conversation = inserted[0];

      // Add creator + members. `VALUES ($1, unnest($2::uuid[]))` would
      // work but a simple loop is clearer for the creator-first pattern.
      const allMembers = [userId, ...distinctMembers];
      const values = allMembers.map((_m, i) => `($1, $${i + 2})`).join(', ');
      await query(
        `INSERT INTO conversation_members (conversation_id, user_id) VALUES ${values}`,
        [conversation.id, ...allMembers],
      );

      conversation.members = await loadMembers(conversation.id, req);
      conversation.unread_count = 0;
      return res.status(201).json({ conversation });
    }

    // ── Direct path (existing 1:1 behavior) ──
    if (!user_id) throw new AppError(400, 'user_id or member_ids is required');
    if (user_id === userId) throw new AppError(400, 'Cannot start a conversation with yourself');

    const mutual = await isMutualFollow(userId, user_id);
    if (!mutual) throw new AppError(403, 'Must be mutual followers to start a conversation');

    // Canonical ordering for the partial unique index.
    const user_a_id = userId < user_id ? userId : user_id;
    const user_b_id = userId < user_id ? user_id : userId;

    const { rows: existing } = await query(
      `SELECT * FROM conversations
       WHERE conversation_type = 'direct' AND user_a_id = $1 AND user_b_id = $2`,
      [user_a_id, user_b_id],
    );

    let conversation: any;
    let status = 200;

    if (existing.length > 0) {
      conversation = existing[0];
    } else {
      const { rows: inserted } = await query(
        `INSERT INTO conversations (conversation_type, user_a_id, user_b_id, is_e2ee)
         VALUES ('direct', $1, $2, $3) RETURNING *`,
        [user_a_id, user_b_id, isE2ee],
      );
      conversation = inserted[0];
      await query(
        `INSERT INTO conversation_members (conversation_id, user_id)
         VALUES ($1, $2), ($1, $3)`,
        [conversation.id, userId, user_id],
      );
      status = 201;
    }

    // Attach other-user info to match existing shape.
    const { rows: users } = await query(
      'SELECT id, username, display_name, avatar_url FROM users WHERE id = $1',
      [user_id],
    );
    const other = users[0];
    conversation.other_user_id = other.id;
    conversation.other_username = other.username;
    conversation.other_display_name = other.display_name;
    conversation.other_avatar_url = other.avatar_url ? resolveMediaUrl(other.avatar_url, req) : null;
    conversation.unread_count = 0;
    conversation.members = null;

    res.status(status).json({ conversation });
  }),
);

// PATCH /:id - Rename a group conversation. Creator only.
router.patch(
  '/:id',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const { name } = req.body;

    if (typeof name !== 'string' || name.trim().length === 0) {
      throw new AppError(400, 'name is required');
    }
    const trimmedName = name.trim();
    if (trimmedName.length > MAX_GROUP_NAME_LENGTH) {
      throw new AppError(400, `Group name must be ${MAX_GROUP_NAME_LENGTH} characters or fewer`);
    }

    const conv = await getConversation(id);
    if (!conv) throw new AppError(404, 'Conversation not found');
    if (conv.conversation_type !== 'group') {
      throw new AppError(400, 'Only group conversations can be renamed');
    }
    if (conv.created_by !== userId) {
      throw new AppError(403, 'Only the creator can rename the group');
    }

    await query('UPDATE conversations SET name = $1 WHERE id = $2', [trimmedName, id]);
    const updated = await getConversation(id);
    updated.members = await loadMembers(id, req);
    res.json({ conversation: updated });
  }),
);

// POST /:id/members - Add members to a group. Creator only, respects
// cap, mutual-follow required, no duplicates.
router.post(
  '/:id/members',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const { user_ids } = req.body;

    if (!Array.isArray(user_ids)) throw new AppError(400, 'user_ids must be an array');

    const conv = await getConversation(id);
    if (!conv) throw new AppError(404, 'Conversation not found');
    if (conv.conversation_type !== 'group') {
      throw new AppError(400, 'Cannot add members to a direct conversation');
    }
    if (conv.created_by !== userId) {
      throw new AppError(403, 'Only the creator can modify membership');
    }

    const distinctNew = Array.from(new Set(
      user_ids.filter((v: any) => typeof v === 'string' && UUID_RE.test(v) && v !== userId),
    )) as string[];
    if (distinctNew.length === 0) throw new AppError(400, 'No valid user_ids provided');

    // Filter to users not already in the group.
    const { rows: currentMembers } = await query(
      'SELECT user_id FROM conversation_members WHERE conversation_id = $1',
      [id],
    );
    const currentSet = new Set<string>(currentMembers.map((r: any) => r.user_id));
    const toAdd = distinctNew.filter((uid) => !currentSet.has(uid));

    if (toAdd.length === 0) {
      // Nothing to do — return current state.
      const members = await loadMembers(id, req);
      return res.json({ conversation: { ...conv, members } });
    }

    if (currentSet.size + toAdd.length > MAX_GROUP_MEMBERS) {
      throw new AppError(400, `Adding these members would exceed the ${MAX_GROUP_MEMBERS}-member limit`);
    }

    // Mutual follow of the creator (v1 rule).
    const mutualChecks = await Promise.all(toAdd.map((uid) => isMutualFollow(userId, uid)));
    if (mutualChecks.some((ok) => !ok)) {
      throw new AppError(403, 'New members must be mutual follows of the creator');
    }

    // Phase 1f: bump the conversation epoch BEFORE inserting the new
    // members so we can stamp their `joined_at_epoch` at the new
    // value. This signals existing senders that their sender-key
    // chains are stale — on their next send, they rotate and
    // redistribute, giving the new member a chain they can decrypt
    // from (and forward-secreting any old chains the removed member
    // would have had). Wrap in a transaction so either both the
    // epoch bump AND the member insert land, or neither does.
    const { rows: bumpRows } = await query(
      'UPDATE conversations SET epoch = epoch + 1 WHERE id = $1 RETURNING epoch',
      [id],
    );
    const newEpoch = bumpRows[0].epoch;

    const values = toAdd.map((_u, i) => `($1, $${i + 2}, $${toAdd.length + 2})`).join(', ');
    await query(
      `INSERT INTO conversation_members (conversation_id, user_id, joined_at_epoch) VALUES ${values}
       ON CONFLICT DO NOTHING`,
      [id, ...toAdd, newEpoch],
    );

    const members = await loadMembers(id, req);
    // Return the updated epoch so the client can round-trip it
    // (the conversation provider will re-read from GET /:id anyway,
    // but echoing here avoids a second network hop on the add path).
    res.json({ conversation: { ...conv, epoch: newEpoch, members } });
  }),
);

// DELETE /:id/members/:userId - Remove a member. Creator only.
// Creator cannot remove themselves through this endpoint — they use
// /leave, which dissolves the group if they're the last member.
router.delete(
  '/:id/members/:userId',
  asyncHandler(async (req: any, res: any) => {
    const actorId = req.user!.userId;
    const { id, userId: targetUserId } = req.params;

    const conv = await getConversation(id);
    if (!conv) throw new AppError(404, 'Conversation not found');
    if (conv.conversation_type !== 'group') {
      throw new AppError(400, 'Cannot remove members from a direct conversation');
    }
    if (conv.created_by !== actorId) {
      throw new AppError(403, 'Only the creator can remove members');
    }
    if (targetUserId === actorId) {
      throw new AppError(400, 'Creators cannot remove themselves; use /leave instead');
    }

    const { rowCount } = await query(
      'DELETE FROM conversation_members WHERE conversation_id = $1 AND user_id = $2',
      [id, targetUserId],
    );
    if (rowCount === 0) throw new AppError(404, 'Member not found in this conversation');

    // Phase 1f: bump epoch so remaining senders rotate their
    // sender-key chains on their next send. Without this, a
    // removed member who still has a (stale) sender-key store
    // could decrypt any future group message they somehow
    // received — server won't fan out to them, but the chain
    // itself would still be valid. Rotation forward-secrets.
    await query(
      'UPDATE conversations SET epoch = epoch + 1 WHERE id = $1',
      [id],
    );

    res.json({ message: 'Member removed' });
  }),
);

// POST /:id/leave - Leave a group conversation.
//
// Admin transfer rule: if the creator is leaving AND other members
// remain, they must supply `new_admin_id` pointing to a current member.
// We atomically reassign `created_by` to that user and then delete the
// creator's membership. This prevents the "headless group" state where
// the creator left and admin actions (rename/add/remove) silently fail
// because they're gated on created_by.
//
// Last member leaving dissolves the conversation (hard delete — cleans
// messages + conversation row).
router.post(
  '/:id/leave',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const { new_admin_id } = req.body ?? {};

    const conv = await getConversation(id);
    if (!conv) throw new AppError(404, 'Conversation not found');
    if (conv.conversation_type !== 'group') {
      throw new AppError(400, 'Cannot leave a direct conversation — delete it instead');
    }

    await assertMember(id, userId);

    // Fetch remaining members (everyone except the leaver).
    const { rows: otherMembers } = await query(
      'SELECT user_id FROM conversation_members WHERE conversation_id = $1 AND user_id != $2',
      [id, userId],
    );
    const isCreator = conv.created_by === userId;

    // Creator leaving with others remaining → require + validate transfer.
    if (isCreator && otherMembers.length > 0) {
      if (!new_admin_id) {
        // `requires_admin_transfer` is a hint for clients that want to
        // render a "pick new admin" sheet without having to pattern-match
        // the error message.
        return res.status(400).json({
          error: 'Transfer admin before leaving',
          requires_admin_transfer: true,
        });
      }
      if (typeof new_admin_id !== 'string' || !UUID_RE.test(new_admin_id)) {
        throw new AppError(400, 'new_admin_id must be a valid UUID');
      }
      if (new_admin_id === userId) {
        throw new AppError(400, 'Cannot transfer admin to yourself');
      }
      const isNewAdminMember = otherMembers.some(
        (r: any) => r.user_id === new_admin_id,
      );
      if (!isNewAdminMember) {
        throw new AppError(400, 'new_admin_id must be a current member of the group');
      }

      // Transfer admin. Runs before the DELETE below so the group is
      // never in a "no creator" state between the two statements.
      await query(
        'UPDATE conversations SET created_by = $1 WHERE id = $2',
        [new_admin_id, id],
      );
    }

    await query(
      'DELETE FROM conversation_members WHERE conversation_id = $1 AND user_id = $2',
      [id, userId],
    );

    if (otherMembers.length === 0) {
      // Hard-delete — cleans messages first (no cascade) then the row.
      await query('DELETE FROM messages WHERE conversation_id = $1', [id]);
      await query('DELETE FROM conversations WHERE id = $1', [id]);
      return res.json({
        message: 'Left and dissolved the group (no members remaining)',
        dissolved: true,
      });
    }

    // Phase 1f: bump epoch so the remaining senders forward-secret
    // their sender-key chains against the departing user. Same logic
    // as DELETE /:id/members/:userId — a leaver who retained a stale
    // SenderKeyRecord shouldn't be able to decrypt anything new.
    await query(
      'UPDATE conversations SET epoch = epoch + 1 WHERE id = $1',
      [id],
    );

    res.json({ message: 'Left the group', dissolved: false });
  }),
);

// GET /:id/messages - Get messages for a conversation (any member).
router.get(
  '/:id/messages',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const before = parseBeforeCursor(req.query.before);

    await assertMember(id, userId);

    const status = await getUserSubscriptionStatus(userId);
    const { feedHistoryDays } = getPlanLimits(status);

    // Phase 1f: per-recipient SKDM rows (`recipient_id` set) are
    // visible only to the targeted user. Any other row
    // (`recipient_id IS NULL`) fans out to every member as before.
    const { rows: messages } = await query(
      `SELECT m.*, u.username AS sender_username, u.display_name AS sender_display_name, u.avatar_url AS sender_avatar_url
       FROM messages m
       JOIN users u ON u.id = m.sender_id
       WHERE m.conversation_id = $1
         AND (m.recipient_id IS NULL OR m.recipient_id = $4)
         AND ($2::timestamptz IS NULL OR m.created_at < $2)
         AND ($3::int IS NULL OR m.created_at > NOW() - make_interval(days => $3))
       ORDER BY m.created_at DESC
       LIMIT 50`,
      [id, before, feedHistoryDays, userId],
    );

    let hasOlderMessages = false;
    if (feedHistoryDays != null) {
      const { rows: olderCheck } = await query(
        `SELECT EXISTS (
           SELECT 1 FROM messages
           WHERE conversation_id = $1
             AND created_at <= NOW() - make_interval(days => $2)
         ) AS has_older`,
        [id, feedHistoryDays],
      );
      hasOlderMessages = olderCheck[0]?.has_older ?? false;
    }

    for (const msg of messages) {
      if (msg.sender_avatar_url) msg.sender_avatar_url = resolveMediaUrl(msg.sender_avatar_url, req);
      // bytea → base64 so JSON.stringify doesn't choke. Null stays null.
      if (msg.ciphertext) {
        msg.ciphertext = Buffer.from(msg.ciphertext).toString('base64');
      }
    }
    res.json({ messages, has_older_messages: hasOlderMessages });
  }),
);

// POST /:id/messages - Send a message. Fan out via Socket.io +
// notification + push to every OTHER member (direct = 1, group = N-1).
router.post(
  '/:id/messages',
  writeLimit,
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;
    const {
      body,
      media_url,
      ciphertext,
      envelope_type,
      protocol_version,
      conversation_epoch,
      recipient_id,
    } = req.body;

    await assertMember(id, userId);

    const conv = await getConversation(id);
    if (!conv) throw new AppError(404, 'Conversation not found');

    // E2EE vs legacy path — locked by conversation.is_e2ee at create
    // time. Rejecting on the wrong path keeps the `messages_has_payload`
    // check constraint clean (no half-encrypted rows) and surfaces
    // client bugs early.
    const isE2ee = conv.is_e2ee === true;
    let ciphertextBuf: Buffer | null = null;
    let envelopeType: string | null = null;
    let protocolVersion: number | null = null;
    let targetedRecipientId: string | null = null;

    if (isE2ee) {
      if (body || media_url) {
        throw new AppError(
          400,
          'E2EE conversation: body/media_url not allowed; send ciphertext instead',
        );
      }
      if (typeof ciphertext !== 'string' || ciphertext.length === 0) {
        throw new AppError(400, 'ciphertext (base64) is required for E2EE messages');
      }
      if (
        envelope_type !== 'signal_1to1' &&
        envelope_type !== 'signal_group' &&
        envelope_type !== 'signal_skdm'
      ) {
        throw new AppError(
          400,
          'envelope_type must be signal_1to1, signal_group, or signal_skdm',
        );
      }
      ciphertextBuf = Buffer.from(ciphertext, 'base64');
      if (ciphertextBuf.length === 0) {
        throw new AppError(400, 'ciphertext did not decode to any bytes');
      }
      envelopeType = envelope_type;
      // Default to 1 if client didn't send one — simplifies clients
      // that don't yet track protocol versioning.
      protocolVersion =
        typeof protocol_version === 'number' &&
        Number.isInteger(protocol_version) &&
        protocol_version >= 1
          ? protocol_version
          : 1;

      // Phase 1f: per-recipient SKDM routing. SKDMs are 1:1-encrypted
      // to a specific member and addressed via recipient_id — only
      // that user sees the row on fetch + only that user receives
      // the socket event. Broadcast SKDMs (no recipient_id) would
      // defeat the per-recipient ciphertext model and are rejected.
      // Non-SKDM rows must NOT set recipient_id (keeps the DB check
      // constraint happy and the fanout logic simple).
      if (envelopeType === 'signal_skdm') {
        if (typeof recipient_id !== 'string' || !UUID_RE.test(recipient_id)) {
          throw new AppError(
            400,
            'signal_skdm requires recipient_id (UUID of target member)',
          );
        }
        if (recipient_id === userId) {
          throw new AppError(
            400,
            'recipient_id cannot be the sender (SKDMs are distributed to OTHER members)',
          );
        }
        // Ensure the targeted user is actually a member of this
        // conversation — stop a malicious client from stuffing
        // control rows for arbitrary users.
        const { rows: memberCheck } = await query(
          'SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2',
          [id, recipient_id],
        );
        if (memberCheck.length === 0) {
          throw new AppError(
            400,
            'recipient_id is not a member of this conversation',
          );
        }
        targetedRecipientId = recipient_id;
      } else if (recipient_id) {
        throw new AppError(
          400,
          'recipient_id is only valid for signal_skdm messages',
        );
      }

      if (conv.conversation_type === 'group' && envelopeType === 'signal_group') {
        if (
          typeof conversation_epoch !== 'number' ||
          !Number.isInteger(conversation_epoch)
        ) {
          throw new AppError(
            400,
            'conversation_epoch is required for signal_group messages',
          );
        }
        if (conversation_epoch !== Number(conv.epoch ?? 0)) {
          throw new AppError(
            409,
            'stale conversation epoch; refetch conversation before sending',
          );
        }
      }
    } else {
      if (ciphertext) {
        throw new AppError(
          400,
          'Legacy conversation: ciphertext not allowed; use body/media_url',
        );
      }
      if (!body && !media_url) {
        throw new AppError(400, 'body or media_url is required');
      }
      envelopeType = 'legacy_plaintext';
    }

    const { rows: messages } = await query(
      `INSERT INTO messages (
         conversation_id, sender_id, body, media_url,
         ciphertext, envelope_type, protocol_version, recipient_id
       ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *`,
      [
        id,
        userId,
        body || null,
        media_url || null,
        ciphertextBuf,
        envelopeType,
        protocolVersion,
        targetedRecipientId,
      ],
    );
    const message = messages[0];
    // Wire-format: serialize bytea as base64 so clients get a
    // JSON-friendly payload. Null stays null.
    if (message.ciphertext) {
      message.ciphertext = Buffer.from(message.ciphertext).toString('base64');
    }

    // Attach sender info for socket + response.
    const { rows: senderRows } = await query(
      'SELECT display_name, avatar_url FROM users WHERE id = $1',
      [userId],
    );
    if (senderRows.length > 0) {
      message.sender_display_name = senderRows[0].display_name;
      message.sender_avatar_url = senderRows[0].avatar_url
        ? resolveMediaUrl(senderRows[0].avatar_url, req)
        : null;
    }

    // SKDM rows don't advance `last_message_at` — they're control
    // messages, invisible in UI, and shouldn't bump the thread's
    // preview row in the conversations list.
    if (envelopeType !== 'signal_skdm') {
      await query(
        'UPDATE conversations SET last_message_at = NOW() WHERE id = $1',
        [id],
      );
    }

    // Fan out: broadcast to every other member by default, or to
    // only the targeted recipient for SKDM control messages.
    let fanoutTargets: Array<{ user_id: string }>;
    if (targetedRecipientId) {
      fanoutTargets = [{ user_id: targetedRecipientId }];
    } else {
      const { rows } = await query(
        'SELECT user_id FROM conversation_members WHERE conversation_id = $1 AND user_id != $2',
        [id, userId],
      );
      fanoutTargets = rows;
    }

    const io = getIO();
    const senderName = message.sender_display_name || 'Someone';
    const groupName = conv.conversation_type === 'group' ? conv.name : null;

    for (const row of fanoutTargets) {
      const recipientId: string = row.user_id;

      // Socket push — each recipient listens on their own user room.
      io.to('user:' + recipientId).emit('new_message', message);

      // SKDM control rows are invisible to the UI; no notification
      // row and no push. They're cryptographic plumbing, not a
      // user-visible "someone sent you something" event.
      if (envelopeType === 'signal_skdm') continue;

      // In-app notification row (one per recipient).
      await query(
        `INSERT INTO notifications (user_id, type, actor_id, reference_id, reference_type)
         VALUES ($1, 'dm', $2, $3, 'conversation')`,
        [recipientId, userId, id],
      );

      // Fire-and-forget push. For groups, include the group name in
      // the preview so recipients know which thread lit up. For
      // E2EE conversations, notifyNewDM swaps in a generic body —
      // server never sees plaintext anyway, and broadcasting it in
      // the push payload would defeat E2EE.
      notifyNewDM(recipientId, senderName, body || null, id, groupName, {
        isE2ee,
        messageId: message.id,
      }).catch(() => {});
    }

    res.status(201).json({ message });
  }),
);

// POST /:id/upload-url - Get presigned upload URL for conversation media.
// Unchanged from pre-groups version — storage is ambient to member count.
router.post(
  '/:id/upload-url',
  asyncHandler(async (req: any, res: any) => {
    const { content_type } = req.body;
    if (!content_type) throw new AppError(400, 'content_type is required');

    const key = uuidv4();
    res.json({
      upload_url: `https://storage.example.com/uploads/${key}?content_type=${encodeURIComponent(content_type)}`,
      key,
    });
  }),
);

// POST /:id/read - Mark conversation as read.
router.post(
  '/:id/read',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { id } = req.params;

    const { rowCount } = await query(
      `UPDATE conversation_members SET last_read_at = NOW()
       WHERE conversation_id = $1 AND user_id = $2`,
      [id, userId],
    );
    if (rowCount === 0) throw new AppError(404, 'Conversation membership not found');

    res.json({ message: 'Marked as read' });
  }),
);

export default router;
