-- Define one explicit deletion policy for every relationship to users.
--
-- Private/dependent data is removed with the user. Shared operational
-- history remains, but its user pointer is nulled. A BEFORE DELETE trigger
-- records storage keys before relational cascades remove their source rows.

CREATE TABLE media_deletion_queue (
  object_key text PRIMARY KEY,
  enqueued_at timestamptz NOT NULL DEFAULT now(),
  last_attempt_at timestamptz,
  attempts integer NOT NULL DEFAULT 0,
  last_error text
);

CREATE TABLE dm_attachment_objects (
  object_key text PRIMARY KEY,
  uploaded_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_dm_attachment_objects_user
  ON dm_attachment_objects (uploaded_by_user_id);

-- Historical operator records survive deletion, without forcing the user row
-- to remain forever solely as a foreign-key target.
ALTER TABLE admin_audit ALTER COLUMN admin_user_id DROP NOT NULL;
ALTER TABLE broadcasts ALTER COLUMN initiated_by_user_id DROP NOT NULL;

ALTER TABLE invites DROP CONSTRAINT invites_created_by_user_id_fkey;
ALTER TABLE invites ADD CONSTRAINT invites_created_by_user_id_fkey
  FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE invites DROP CONSTRAINT invites_used_by_user_id_fkey;
ALTER TABLE invites ADD CONSTRAINT invites_used_by_user_id_fkey
  FOREIGN KEY (used_by_user_id) REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE follows DROP CONSTRAINT follows_follower_id_fkey;
ALTER TABLE follows ADD CONSTRAINT follows_follower_id_fkey
  FOREIGN KEY (follower_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE follows DROP CONSTRAINT follows_followee_id_fkey;
ALTER TABLE follows ADD CONSTRAINT follows_followee_id_fkey
  FOREIGN KEY (followee_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE posts DROP CONSTRAINT posts_user_id_fkey;
ALTER TABLE posts ADD CONSTRAINT posts_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE groups DROP CONSTRAINT groups_user_id_fkey;
ALTER TABLE groups ADD CONSTRAINT groups_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE group_members DROP CONSTRAINT group_members_member_user_id_fkey;
ALTER TABLE group_members ADD CONSTRAINT group_members_member_user_id_fkey
  FOREIGN KEY (member_user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE comments DROP CONSTRAINT comments_post_id_fkey;
ALTER TABLE comments ADD CONSTRAINT comments_post_id_fkey
  FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE;
ALTER TABLE comments DROP CONSTRAINT comments_user_id_fkey;
ALTER TABLE comments ADD CONSTRAINT comments_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE stories DROP CONSTRAINT stories_user_id_fkey;
ALTER TABLE stories ADD CONSTRAINT stories_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

-- Direct conversations disappear when either participant is deleted. Group
-- conversations have NULL user_a/user_b and retain their remaining members.
ALTER TABLE conversations DROP CONSTRAINT conversations_user_a_id_fkey;
ALTER TABLE conversations ADD CONSTRAINT conversations_user_a_id_fkey
  FOREIGN KEY (user_a_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE conversations DROP CONSTRAINT conversations_user_b_id_fkey;
ALTER TABLE conversations ADD CONSTRAINT conversations_user_b_id_fkey
  FOREIGN KEY (user_b_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE conversations DROP CONSTRAINT conversations_created_by_fkey;
ALTER TABLE conversations ADD CONSTRAINT conversations_created_by_fkey
  FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE conversation_members DROP CONSTRAINT conversation_members_user_id_fkey;
ALTER TABLE conversation_members ADD CONSTRAINT conversation_members_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE messages DROP CONSTRAINT messages_conversation_id_fkey;
ALTER TABLE messages ADD CONSTRAINT messages_conversation_id_fkey
  FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE;
ALTER TABLE messages DROP CONSTRAINT messages_sender_id_fkey;
ALTER TABLE messages ADD CONSTRAINT messages_sender_id_fkey
  FOREIGN KEY (sender_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE notifications DROP CONSTRAINT notifications_user_id_fkey;
ALTER TABLE notifications ADD CONSTRAINT notifications_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE notifications DROP CONSTRAINT notifications_actor_id_fkey;
ALTER TABLE notifications ADD CONSTRAINT notifications_actor_id_fkey
  FOREIGN KEY (actor_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE refresh_tokens DROP CONSTRAINT refresh_tokens_user_id_fkey;
ALTER TABLE refresh_tokens ADD CONSTRAINT refresh_tokens_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE admin_audit DROP CONSTRAINT admin_audit_admin_user_id_fkey;
ALTER TABLE admin_audit ADD CONSTRAINT admin_audit_admin_user_id_fkey
  FOREIGN KEY (admin_user_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE admin_audit DROP CONSTRAINT admin_audit_target_user_id_fkey;
ALTER TABLE admin_audit ADD CONSTRAINT admin_audit_target_user_id_fkey
  FOREIGN KEY (target_user_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE broadcasts DROP CONSTRAINT broadcasts_initiated_by_user_id_fkey;
ALTER TABLE broadcasts ADD CONSTRAINT broadcasts_initiated_by_user_id_fkey
  FOREIGN KEY (initiated_by_user_id) REFERENCES users(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION enqueue_deleted_user_media()
RETURNS trigger AS $$
BEGIN
  INSERT INTO media_deletion_queue (object_key)
  SELECT DISTINCT media.object_key
  FROM (
    SELECT OLD.avatar_url
    UNION ALL
    SELECT pm.media_url
      FROM post_media pm JOIN posts p ON p.id = pm.post_id
      WHERE p.user_id = OLD.id
    UNION ALL
    SELECT pm.thumbnail_url
      FROM post_media pm JOIN posts p ON p.id = pm.post_id
      WHERE p.user_id = OLD.id
    UNION ALL
    SELECT s.media_url FROM stories s WHERE s.user_id = OLD.id
    UNION ALL
    SELECT m.media_url
      FROM messages m
      WHERE m.sender_id = OLD.id
         OR m.recipient_id = OLD.id
         OR m.conversation_id IN (
           SELECT c.id FROM conversations c
           WHERE c.conversation_type = 'direct'
             AND (c.user_a_id = OLD.id OR c.user_b_id = OLD.id)
         )
    UNION ALL
    SELECT d.object_key
      FROM dm_attachment_objects d
      WHERE d.uploaded_by_user_id = OLD.id
  ) AS media(object_key)
  WHERE media.object_key IS NOT NULL
    AND media.object_key != ''
    AND media.object_key !~* '^https?://'
  ON CONFLICT (object_key) DO NOTHING;

  -- User-targeted audit payloads can contain before/after email addresses.
  -- Keep the action/timestamp trail but remove its target-specific payload.
  UPDATE admin_audit
     SET details = NULL
   WHERE target_user_id = OLD.id;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_enqueue_media_before_delete
BEFORE DELETE ON users
FOR EACH ROW EXECUTE FUNCTION enqueue_deleted_user_media();
