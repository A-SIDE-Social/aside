-- Add thumbnail_url to post_media so videos have a still representative
-- frame for surfaces that can't play video (iOS/Android home-screen
-- widgets, press cards, preview thumbnails, feed grid cells). The
-- thumbnail is an S3 key stored the same way as media_url and resolved
-- to a CDN URL at read time via resolveMediaUrl.
--
-- Photos don't need this — the media_url itself is the still. The
-- column is therefore nullable; on photo rows it stays NULL, on video
-- rows we set it at upload time to a first-frame JPEG extracted on the
-- client and uploaded alongside the video.
--
-- Older video rows (posted before this migration) remain NULL. Widget
-- + grid cells fall back to their existing behavior (skip, or load the
-- full video to seek frame 0 — slow but correct).

ALTER TABLE post_media ADD COLUMN thumbnail_url text;
