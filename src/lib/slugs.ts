// Personal invite-link slug generation.
//
// A slug is a 12-character lowercase alphanumeric string used as the
// path of a user's personal invite URL.
// 12 chars from `[a-z0-9]` is 36^12 ≈ 4.7 × 10^18 possibilities, which
// makes accidental collisions and brute-force enumeration both
// negligible.
//
// Slugs are never typed by humans — they ride in URLs and QR codes —
// so the alphabet does not exclude visually-ambiguous characters
// (0/o/1/l/i). The full lowercase alphanumeric set keeps the keyspace
// as large as possible.

import { randomBytes } from 'node:crypto';

export const SLUG_LENGTH = 12;
const ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';
export const SLUG_REGEX = /^[a-z0-9]{12}$/;

// Reserved web paths that the public marketing site uses or might use.
// The natural collision probability is effectively zero (none of these
// are 12 chars), but the guard is essentially free and protects
// against accidental future overlap with newly-added named routes.
//
// AASA / App-Links pattern matching is the primary defense (it limits
// universal-link interception to 12-char paths). This list is a
// belt-and-suspenders fallback for the generator.
export const RESERVED_SLUGS = new Set<string>([
  'about',
  'blog',
  'privacy',
  'terms',
  'rss',
  'rss.xml',
  'sitemap',
  'sitemap.xml',
  'favicon',
  'favicon.ico',
  'robots',
  'robots.txt',
  'well-known',
  '.well-known',
  'api',
  'app',
  'admin',
  'health',
  'unsubscribe',
  'child-safety',
  'encrypted-messaging',
  'family-photo-app',
  'private-photo-sharing',
  'no-ads-no-ai',
  'how-to-leave-instagram',
  'inside-meta-privacy-policy',
]);

// Generate a single random 12-char slug. Uses crypto.randomBytes for
// cryptographic-grade randomness — Math.random's predictability would
// make slug enumeration theoretically possible if seeds aligned.
//
// We sample one byte per output character and reject bytes whose
// modulo-36 reduction would introduce bias (anything >= 252, since
// 252 is the largest multiple of 36 that fits in a byte). The
// expected rejection rate is ~1.5%, so generating 12 chars takes ~12
// bytes on average and never more than a handful of retries.
export function generateSlug(): string {
  const out: string[] = [];
  while (out.length < SLUG_LENGTH) {
    const buf = randomBytes(SLUG_LENGTH * 2); // overshoot to minimize re-reads
    for (let i = 0; i < buf.length && out.length < SLUG_LENGTH; i++) {
      const b = buf[i];
      if (b >= 252) continue; // reject to avoid modulo bias
      out.push(ALPHABET[b % 36]);
    }
  }
  return out.join('');
}

// Generate a slug that is not in the reserved list. Loops until it
// produces a non-reserved candidate. With 12-char outputs and no
// 12-char reserved entries, this is effectively a no-op pass-through,
// but the guard is here for forward compatibility.
export function generateNonReservedSlug(): string {
  let candidate = generateSlug();
  while (RESERVED_SLUGS.has(candidate)) {
    candidate = generateSlug();
  }
  return candidate;
}

// Generate a slug that is both non-reserved and unique against the
// database. Caller provides a `isTaken` predicate so this module
// stays decoupled from the db pool — useful for tests and for
// running inside or outside an explicit transaction.
//
// Bounded retry count: with 4.7e18 possibilities and ~10k users, the
// natural collision odds per attempt are ~2e-15. Eleven attempts is
// massive overkill but cheap, and `RAISE` if exhausted is more
// debuggable than an infinite loop.
export async function generateUniqueSlug(
  isTaken: (slug: string) => Promise<boolean>,
  maxAttempts = 11,
): Promise<string> {
  for (let i = 0; i < maxAttempts; i++) {
    const candidate = generateNonReservedSlug();
    if (!(await isTaken(candidate))) return candidate;
  }
  throw new Error(`Could not generate unique slug after ${maxAttempts} attempts`);
}

// Extract a slug from a free-form input — accepts either:
//   - A bare slug: "k7m2pq9xj4n6"
//   - A full URL: "https://example.com/k7m2pq9xj4n6"
//   - A URL with trailing slash, query, or fragment.
// Returns null if the input doesn't match the slug shape.
//
// Used by the signup-field disambiguator in src/routes/auth.ts to
// figure out whether the user pasted a URL, a slug, or a legacy
// 12-char alphanumeric invite code. Slug regex is stricter than
// legacy-code regex (lowercase only vs mixed case), so call this
// first; if it returns null, fall through to legacy-code parsing.
export function extractSlug(
  input: string,
  allowedHosts?: string[],
): string | null {
  if (!input) return null;
  const trimmed = input.trim();

  // Bare slug
  if (SLUG_REGEX.test(trimmed)) return trimmed;

  // URL — extract the first path segment and test it. When the caller
  // passes allowed hosts, reject URLs for other domains while still
  // accepting bare slugs.
  let url: URL;
  try {
    url = new URL(trimmed.includes('://') ? trimmed : `https://${trimmed}`);
  } catch {
    return null;
  }
  if (allowedHosts?.length) {
    const host = url.hostname.toLowerCase();
    if (!allowedHosts.map((h) => h.toLowerCase()).includes(host)) {
      return null;
    }
  }
  const firstSegment = url.pathname.split('/').filter(Boolean)[0];
  if (firstSegment && SLUG_REGEX.test(firstSegment)) return firstSegment;
  return null;
}
