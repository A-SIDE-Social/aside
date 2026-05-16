/**
 * Pure-function unit tests. No DB, no HTTP — fast feedback for the small
 * helpers introduced in build 25.
 */
import { parseBeforeCursor } from '../src/helpers';
import { buildNewPostBody } from '../src/firebase';
import { AppError } from '../src/middleware/errorHandler';
import { LIMITS } from '../src/constants';

describe('parseBeforeCursor', () => {
  test('returns null for undefined / null / empty', () => {
    expect(parseBeforeCursor(undefined)).toBeNull();
    expect(parseBeforeCursor(null)).toBeNull();
    expect(parseBeforeCursor('')).toBeNull();
  });

  test('passes through a valid ISO-8601 timestamp', () => {
    const iso = '2026-04-14T23:28:12.169Z';
    expect(parseBeforeCursor(iso)).toBe(iso);
  });

  test('passes through a Postgres-style timestamptz string', () => {
    // Postgres returns timestamps in this format from json output; Date.parse
    // accepts them, so they should round-trip the helper unchanged.
    const ts = '2026-04-14 23:28:12.169264+00';
    expect(parseBeforeCursor(ts)).toBe(ts);
  });

  test('throws 400 on a UUID — the build 25 regression case', () => {
    // Old mobile clients sent the last post's id as the cursor, which
    // surfaced from Postgres as a 500 DateTimeParseError. The helper now
    // catches it before it reaches the SQL layer.
    expect(() => parseBeforeCursor('78393e4a-e783-4163-b1c6-a9068d4c30e3'))
      .toThrow(AppError);
    try {
      parseBeforeCursor('78393e4a-e783-4163-b1c6-a9068d4c30e3');
    } catch (e: any) {
      expect(e.statusCode).toBe(400);
    }
  });

  test('throws 400 on arbitrary garbage', () => {
    expect(() => parseBeforeCursor('not-a-date')).toThrow(AppError);
    expect(() => parseBeforeCursor('🦄')).toThrow(AppError);
  });

  test('throws 400 on non-string types', () => {
    expect(() => parseBeforeCursor(12345)).toThrow(AppError);
    expect(() => parseBeforeCursor({ ts: 'now' })).toThrow(AppError);
    expect(() => parseBeforeCursor(['2026-04-14'])).toThrow(AppError);
  });
});

describe('buildNewPostBody', () => {
  test('uses the caption verbatim when present', () => {
    expect(buildNewPostBody('hello world', ['photo'])).toBe('hello world');
  });

  test('truncates long captions to 100 chars + ellipsis', () => {
    const long = 'a'.repeat(150);
    const out = buildNewPostBody(long, ['photo']);
    expect(out.length).toBe(101); // 100 chars + the ellipsis character
    expect(out.endsWith('…')).toBe(true);
  });

  test('does not truncate captions exactly at 100 chars', () => {
    const exact = 'a'.repeat(100);
    expect(buildNewPostBody(exact, ['photo'])).toBe(exact);
  });

  test('trims whitespace-only captions and falls back to media descriptor', () => {
    expect(buildNewPostBody('   ', ['photo'])).toBe('Shared a photo');
    expect(buildNewPostBody('\n\t', ['video'])).toBe('Shared a video');
  });

  test('falls back to "Shared a photo" for a single-photo post with no caption', () => {
    expect(buildNewPostBody(null, ['photo'])).toBe('Shared a photo');
  });

  test('falls back to "Shared a video" for a single-video post with no caption', () => {
    expect(buildNewPostBody(null, ['video'])).toBe('Shared a video');
  });

  test('falls back to "Shared a carousel" for any multi-media post with no caption', () => {
    // Build 25 fix: the old code always said "shared an image" even for
    // mixed-media or video carousels.
    expect(buildNewPostBody(null, ['photo', 'photo'])).toBe('Shared a carousel');
    expect(buildNewPostBody(null, ['photo', 'video'])).toBe('Shared a carousel');
    expect(buildNewPostBody(null, ['video', 'video', 'photo'])).toBe('Shared a carousel');
  });

  test('falls back to "Shared a post" for a text-only post with no caption', () => {
    // Edge case: no caption AND no media. Shouldn't happen in practice
    // (POST /v1/posts rejects it) but the helper should still return
    // something sensible rather than crashing.
    expect(buildNewPostBody(null, [])).toBe('Shared a post');
  });
});

describe('LIMITS constants (build 25 bump)', () => {
  // Guardrail: caption length matches Instagram's 2,200 so voice-dictated
  // captions aren't clipped. If this test fails because someone changed
  // the constant, they also need to update mobile/lib/core/config/constants.dart
  // so the two stay in sync.
  test('maxCaptionLength is 2200', () => {
    expect(LIMITS.maxCaptionLength).toBe(2200);
  });

  test('maxTextPostLength is 2200', () => {
    expect(LIMITS.maxTextPostLength).toBe(2200);
  });
});
