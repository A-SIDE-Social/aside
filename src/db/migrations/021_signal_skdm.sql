-- Phase 1f: per-recipient Sender Key Distribution Messages.
--
-- Group E2EE with Signal's Sender Keys requires each sender to
-- distribute an SKDM to every other member before they can send
-- group-encrypted messages. SKDMs are 1:1-encrypted per recipient
-- (via each pair's Double Ratchet session), so each recipient gets
-- a DIFFERENT ciphertext blob of the same logical SKDM.
--
-- Wire approach: we deliver SKDMs through the group conversation as
-- messages with `envelope_type='signal_skdm'` and `recipient_id` set
-- to the targeted member. The conversations route filters
-- `WHERE recipient_id IS NULL OR recipient_id = :caller` so other
-- members never see rows not addressed to them. Clients decode the
-- envelope, see the `group_skdm` inner type, feed the SKDM into
-- their sender-key store, and suppress the message from the UI.
--
-- 'signal_group' envelopes stay broadcast (recipient_id IS NULL) —
-- there's a single ciphertext every member can decrypt with the
-- sender's stored sender-key chain.

ALTER TABLE messages
  -- Optional targeted recipient for per-member control messages.
  -- When NULL (the default), the message is visible to every member
  -- of the conversation; when set, only that user sees it. Foreign
  -- key + ON DELETE CASCADE so user deletion cleans up orphaned
  -- control rows.
  ADD COLUMN recipient_id uuid REFERENCES users(id) ON DELETE CASCADE;

-- Extend the envelope_type CHECK to allow 'signal_skdm'. Postgres
-- doesn't support ALTER CONSTRAINT directly, so drop + recreate.
ALTER TABLE messages
  DROP CONSTRAINT IF EXISTS messages_envelope_type_check;
ALTER TABLE messages
  ADD CONSTRAINT messages_envelope_type_check CHECK (
    envelope_type IS NULL OR envelope_type IN (
      'legacy_plaintext',
      'signal_1to1',
      'signal_group',
      'signal_skdm'
    )
  );

-- SKDMs MUST address a recipient; broadcast SKDMs would defeat the
-- per-recipient ciphertext model. We enforce the inverse too:
-- non-SKDM messages must NOT set recipient_id — keeps the "regular
-- messages fan out to everyone" story clean.
ALTER TABLE messages
  ADD CONSTRAINT messages_skdm_recipient CHECK (
    (envelope_type = 'signal_skdm' AND recipient_id IS NOT NULL)
    OR (envelope_type IS DISTINCT FROM 'signal_skdm' AND recipient_id IS NULL)
  );

-- Lookup index for the GET /messages filter. Partial — non-SKDM rows
-- dominate the table and don't benefit from this index.
CREATE INDEX idx_messages_recipient_id
  ON messages (conversation_id, recipient_id)
  WHERE recipient_id IS NOT NULL;
