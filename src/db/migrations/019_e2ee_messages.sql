-- Phase 1d: E2EE message envelope.
--
-- Extends the existing `messages` / `conversations` / `conversation_
-- members` tables rather than creating new ones — per the plan,
-- legacy plaintext threads coexist with E2EE ones (frozen-read-only
-- UX on old threads, new threads start encrypted).
--
-- The envelope we store is libsignal's self-contained blob — a
-- Protobuf CiphertextMessage (PreKeySignalMessage for the first
-- message in a session, SignalMessage afterward, or a Sender Key
-- message for groups). IV and AEAD auth tag are embedded inside,
-- so we don't need separate columns for them.

ALTER TABLE messages
  ADD COLUMN ciphertext bytea,
  ADD COLUMN envelope_type text
    CHECK (
      envelope_type IS NULL OR envelope_type IN (
        'legacy_plaintext',
        'signal_1to1',
        'signal_group'
      )
    ),
  ADD COLUMN protocol_version integer;

-- Self-consistency: a row must carry either a body/media_url pair
-- (plaintext) or a ciphertext (E2EE). We allow both to be NULL only
-- for tombstones (`deleted_at IS NOT NULL`) since deletes may clear
-- payload columns.
ALTER TABLE messages
  ADD CONSTRAINT messages_has_payload CHECK (
    deleted_at IS NOT NULL
    OR body IS NOT NULL
    OR media_url IS NOT NULL
    OR ciphertext IS NOT NULL
  );

-- Backfill legacy rows so API code can rely on envelope_type.
UPDATE messages SET envelope_type = 'legacy_plaintext'
  WHERE envelope_type IS NULL;

ALTER TABLE conversations
  -- Locked at creation time. Once true, plaintext body/media_url are
  -- rejected on subsequent inserts. False conversations stay plain
  -- forever — there's no "upgrade to E2EE" path (locked decision #8
  -- in the plan: freeze legacy threads).
  ADD COLUMN is_e2ee boolean NOT NULL DEFAULT false,
  -- Epoch bumps on membership change (group conversations). Every
  -- envelope carries its epoch so receivers can detect and refresh
  -- stale Sender Keys (Phase 1f). Unused for 1:1 conversations but
  -- cheap to carry.
  ADD COLUMN epoch integer NOT NULL DEFAULT 0;

-- Members track which epoch they joined at. Used in group rekey
-- reconciliation (Phase 1f): a message encrypted under epoch N
-- can only be decrypted by members whose joined_at_epoch <= N.
ALTER TABLE conversation_members
  ADD COLUMN joined_at_epoch integer NOT NULL DEFAULT 0;
