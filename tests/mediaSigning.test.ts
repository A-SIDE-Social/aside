import {
  signGetUrl,
  signingWindowStart,
  SIGNED_LINK_LIFETIME_SECONDS,
  SIGNING_WINDOW_SECONDS,
} from '../src/lib/mediaSigning';

// Credentials from the AWS Signature Version 4 documentation example.
const credentials = {
  accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
  secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
};
const sign = (key: string, host: string, now: Date, lifetimeSeconds = 86400) => signGetUrl({
  host,
  key,
  region: 'us-east-1',
  accessKey: credentials.accessKeyId,
  secretKey: credentials.secretAccessKey,
  now,
  lifetimeSeconds,
});

test('matches the published AWS presigned URL example', () => {
  const url = new URL(sign('test.txt', 'examplebucket.s3.amazonaws.com', new Date('2013-05-24T00:00:00Z')));
  expect(url.searchParams.get('X-Amz-Signature'))
    .toBe('aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
});

test.each([
  ['a nested key', 'voice-captions/clip.m4a', '/voice-captions/clip.m4a'],
  ['characters that need encoding', "odd name+(1)!'*.mp4", '/odd%20name%2B%281%29%21%27%2A.mp4'],
])('encodes the path for %s', (_label, key, path) => {
  const url = sign(key, 'bucket.nyc3.digitaloceanspaces.com', new Date('2026-11-03T12:00:00Z'));
  expect(url).toContain(`https://bucket.nyc3.digitaloceanspaces.com${path}?`);
});

test('links are identical within a window and differ across windows', () => {
  const windowMs = SIGNING_WINDOW_SECONDS * 1000;
  const start = new Date(Math.floor(Date.UTC(2026, 10, 3, 12) / windowMs) * windowMs);
  expect(signingWindowStart(new Date(start.getTime() + 1000))).toEqual(start);
  expect(signingWindowStart(new Date(start.getTime() + windowMs - 1))).toEqual(start);
  expect(signingWindowStart(new Date(start.getTime() + windowMs))).not.toEqual(start);
});

test('every link stays valid well beyond the window it was issued in', () => {
  expect(SIGNED_LINK_LIFETIME_SECONDS).toBeGreaterThanOrEqual(SIGNING_WINDOW_SECONDS * 4);
  expect(SIGNED_LINK_LIFETIME_SECONDS).toBeLessThanOrEqual(7 * 24 * 60 * 60);
});

describe('resolving media URLs', () => {
  const load = (overrides: Record<string, unknown>) => {
    jest.resetModules();
    jest.doMock('../src/config', () => ({ config: {
      nodeEnv: 'production',
      s3Region: 'nyc3',
      s3Bucket: 'media',
      s3Endpoint: 'https://nyc3.digitaloceanspaces.com',
      s3AccessKey: 'key',
      s3SecretKey: 'secret',
      cdnUrl: 'https://media.nyc3.cdn.digitaloceanspaces.com',
      mediaSignedUrls: true,
      mediaSignedUrlsViaCdn: false,
      ...overrides,
    } }));
    return require('../src/storage') as typeof import('../src/storage');
  };
  afterEach(() => jest.dontMock('../src/config'));

  test('with the flag off, links are unchanged', () => {
    const { resolveStorageUrl } = load({ mediaSignedUrls: false });
    expect(resolveStorageUrl('a.jpeg')).toBe('https://media.nyc3.cdn.digitaloceanspaces.com/a.jpeg');
  });

  test('with the flag on, media is signed against the storage host', () => {
    const url = new URL(load({}).resolveStorageUrl('a.jpeg'));
    expect(url.host).toBe('media.nyc3.digitaloceanspaces.com');
    expect(url.pathname).toBe('/a.jpeg');
    expect(url.searchParams.get('X-Amz-Signature')).toMatch(/^[0-9a-f]{64}$/);
    expect(url.searchParams.get('X-Amz-Expires')).toBe(String(SIGNED_LINK_LIFETIME_SECONDS));
  });

  test('the secret key never appears in a link', () => {
    expect(load({ s3SecretKey: 'do-not-leak' }).resolveStorageUrl('a.jpeg')).not.toContain('do-not-leak');
  });

  test('signed links can go through the CDN host', () => {
    const url = new URL(load({ mediaSignedUrlsViaCdn: true }).resolveStorageUrl('a.jpeg'));
    expect(url.host).toBe('media.nyc3.cdn.digitaloceanspaces.com');
    expect(url.searchParams.get('X-Amz-Signature')).toBeTruthy();
  });

  test('avatars stay public, on the CDN', () => {
    expect(load({}).resolveStorageUrl('avatar-1')).toBe('https://media.nyc3.cdn.digitaloceanspaces.com/avatar-1');
  });

  test.each([
    ['CDN host', 'https://media.nyc3.cdn.digitaloceanspaces.com/a.jpeg', 'a.jpeg'],
    ['bucket host', 'https://media.nyc3.digitaloceanspaces.com/a.jpeg', 'a.jpeg'],
    ['bucket path', 'https://nyc3.digitaloceanspaces.com/media/a.jpeg', 'a.jpeg'],
    ['another bucket', 'https://nyc3.digitaloceanspaces.com/other/a.jpeg', null],
    ['another site', 'https://example.com/a.jpeg', null],
    ['not a URL', 'a.jpeg', null],
  ])('finds the key in a stored URL: %s', (_label, value, expected) => {
    expect(load({}).storageKeyFromUrl(value)).toBe(expected);
  });
});
