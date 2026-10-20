ALTER TABLE posts ADD COLUMN voice_caption_duration_ms integer
  CHECK (voice_caption_duration_ms > 0 AND voice_caption_duration_ms <= 60000);

CREATE TABLE post_voice_captions (
  id uuid PRIMARY KEY,
  post_id uuid UNIQUE REFERENCES posts(id) ON DELETE CASCADE,
  uploaded_by_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  object_key text UNIQUE NOT NULL,
  duration_ms integer NOT NULL CHECK (duration_ms BETWEEN 1 AND 60000),
  byte_length integer NOT NULL CHECK (byte_length BETWEEN 12 AND 2097152),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX post_voice_captions_owner ON post_voice_captions(uploaded_by_user_id);
CREATE INDEX post_voice_captions_pending ON post_voice_captions(created_at)
  WHERE post_id IS NULL;

CREATE FUNCTION enqueue_deleted_voice_caption() RETURNS trigger AS $$
BEGIN
  INSERT INTO media_deletion_queue(object_key) VALUES (OLD.object_key)
    ON CONFLICT (object_key) DO NOTHING;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER voice_caption_deletion AFTER DELETE ON post_voice_captions
  FOR EACH ROW EXECUTE FUNCTION enqueue_deleted_voice_caption();
