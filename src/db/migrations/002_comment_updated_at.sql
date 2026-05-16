-- Add updated_at to comments for edit tracking (NULL = never edited)
ALTER TABLE comments ADD COLUMN IF NOT EXISTS updated_at timestamptz;
