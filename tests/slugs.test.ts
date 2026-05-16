/**
 * Pure-function unit tests for the personal-invite-link slug helpers.
 * No DB, no HTTP — fast feedback on generator format + extractor parsing.
 */
import {
  generateSlug,
  generateNonReservedSlug,
  generateUniqueSlug,
  extractSlug,
  RESERVED_SLUGS,
  SLUG_REGEX,
  SLUG_LENGTH,
} from '../src/lib/slugs';

describe('generateSlug', () => {
  test('produces 12 chars from [a-z0-9]', () => {
    for (let i = 0; i < 100; i++) {
      const slug = generateSlug();
      expect(slug).toHaveLength(SLUG_LENGTH);
      expect(SLUG_REGEX.test(slug)).toBe(true);
    }
  });

  test('does not repeat within a small batch (sanity check)', () => {
    // 100 draws from a 4.7e18 space — collisions are essentially
    // impossible. A failure here means the entropy source broke.
    const seen = new Set<string>();
    for (let i = 0; i < 100; i++) {
      const slug = generateSlug();
      expect(seen.has(slug)).toBe(false);
      seen.add(slug);
    }
  });
});

describe('generateNonReservedSlug', () => {
  test('never returns a reserved slug', () => {
    for (let i = 0; i < 50; i++) {
      const slug = generateNonReservedSlug();
      expect(RESERVED_SLUGS.has(slug)).toBe(false);
    }
  });

  test('reserved set contains expected web routes', () => {
    // Smoke test — if someone removes the marketing routes from the
    // reserved set, this fails so they remember the AASA-pattern
    // narrowing is the primary defense and this is just belt-and-
    // suspenders.
    expect(RESERVED_SLUGS.has('about')).toBe(true);
    expect(RESERVED_SLUGS.has('blog')).toBe(true);
    expect(RESERVED_SLUGS.has('privacy')).toBe(true);
    expect(RESERVED_SLUGS.has('child-safety')).toBe(true);
  });
});

describe('generateUniqueSlug', () => {
  test('returns immediately when the predicate returns false', async () => {
    const slug = await generateUniqueSlug(async () => false);
    expect(SLUG_REGEX.test(slug)).toBe(true);
  });

  test('retries when the predicate returns true, then settles', async () => {
    let calls = 0;
    const slug = await generateUniqueSlug(async () => {
      calls += 1;
      return calls < 3; // taken on attempts 1 and 2, free on attempt 3
    });
    expect(SLUG_REGEX.test(slug)).toBe(true);
    expect(calls).toBe(3);
  });

  test('throws when the predicate always returns true', async () => {
    await expect(generateUniqueSlug(async () => true, 3)).rejects.toThrow(
      /Could not generate unique slug/,
    );
  });
});

describe('extractSlug', () => {
  test('returns the input verbatim when it is a bare slug', () => {
    expect(extractSlug('k7m2pq9xj4n6')).toBe('k7m2pq9xj4n6');
    expect(extractSlug('  k7m2pq9xj4n6  ')).toBe('k7m2pq9xj4n6'); // trims
  });

  test('rejects uppercase (bare-slug match is lowercase only)', () => {
    // Strict-lowercase regex is what disambiguates slugs from legacy
    // hex codes when both are 12 chars. A user pasting an uppercase
    // string falls through to legacy-code parsing in the auth route.
    expect(extractSlug('K7M2PQ9XJ4N6')).toBeNull();
  });

  test('rejects wrong-length input', () => {
    expect(extractSlug('short')).toBeNull();
    expect(extractSlug('toolongtobeavalidslug')).toBeNull();
    expect(extractSlug('')).toBeNull();
    expect(extractSlug(null as any)).toBeNull();
  });

  test('extracts from a canonical invite URL', () => {
    expect(extractSlug('https://example.com/k7m2pq9xj4n6')).toBe(
      'k7m2pq9xj4n6',
    );
  });

  test('extracts from a URL with a trailing slash, query, or fragment', () => {
    expect(extractSlug('https://example.com/k7m2pq9xj4n6/')).toBe(
      'k7m2pq9xj4n6',
    );
    expect(extractSlug('https://example.com/k7m2pq9xj4n6?utm=sms')).toBe(
      'k7m2pq9xj4n6',
    );
    expect(extractSlug('https://example.com/k7m2pq9xj4n6#frag')).toBe(
      'k7m2pq9xj4n6',
    );
  });

  test('extracts from a URL with the www subdomain', () => {
    expect(extractSlug('https://www.example.com/k7m2pq9xj4n6')).toBe(
      'k7m2pq9xj4n6',
    );
  });

  test('extracts from a URL pasted without scheme', () => {
    // People paste from SMS/iMessage where preview-card stripping
    // sometimes loses the scheme.
    expect(extractSlug('example.com/k7m2pq9xj4n6')).toBe('k7m2pq9xj4n6');
  });

  test('returns null when the URL path is not slug-shaped', () => {
    expect(extractSlug('https://example.com/about')).toBeNull();
    expect(extractSlug('https://example.com/')).toBeNull();
    expect(extractSlug('https://example.com/encrypted-messaging')).toBeNull();
    // Any 12-char lowercase alphanumeric path segment is slug-shaped
    // and gets extracted — the route handler decides whether it
    // actually maps to a user (404 if not). That's by design.
  });

  test('honors an optional URL host allowlist', () => {
    expect(
      extractSlug('https://example.com/k7m2pq9xj4n6', ['example.com']),
    ).toBe('k7m2pq9xj4n6');
    expect(
      extractSlug('https://other.example/k7m2pq9xj4n6', ['example.com']),
    ).toBeNull();
    expect(extractSlug('k7m2pq9xj4n6', ['example.com'])).toBe(
      'k7m2pq9xj4n6',
    );
  });

  test('returns null on garbage input', () => {
    expect(extractSlug('not a url')).toBeNull();
    expect(extractSlug('http://')).toBeNull();
  });
});
