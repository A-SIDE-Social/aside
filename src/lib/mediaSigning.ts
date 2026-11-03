import { createHash, createHmac } from 'crypto';

// Links stay identical within a window, so caches can reuse them, and remain
// valid well past it, so a screen left open doesn't lose its media.
export const SIGNING_WINDOW_SECONDS = 6 * 60 * 60;
export const SIGNED_LINK_LIFETIME_SECONDS = 48 * 60 * 60;

export interface SignedLinkInput {
  host: string;
  key: string;
  region: string;
  accessKey: string;
  secretKey: string;
  now?: Date;
  lifetimeSeconds?: number;
}

const hmac = (key: Buffer | string, value: string): Buffer =>
  createHmac('sha256', key).update(value).digest();

const encode = (value: string): string =>
  encodeURIComponent(value).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);

const encodePath = (key: string): string => key.split('/').map(encode).join('/');

const amzDate = (date: Date): string => date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');

export function signingWindowStart(now: Date): Date {
  const windowMs = SIGNING_WINDOW_SECONDS * 1000;
  return new Date(Math.floor(now.getTime() / windowMs) * windowMs);
}

/**
 * Builds a Signature Version 4 presigned GET URL for an object.
 *
 * This is synchronous, unlike the SDK's presigner, because media links are
 * resolved while building API responses. Signing makes no network request.
 */
export function signGetUrl(input: SignedLinkInput): string {
  const date = input.now ?? signingWindowStart(new Date());
  const timestamp = amzDate(date);
  const day = timestamp.slice(0, 8);
  const scope = `${day}/${input.region}/s3/aws4_request`;
  const path = `/${encodePath(input.key)}`;
  const query = [
    ['X-Amz-Algorithm', 'AWS4-HMAC-SHA256'],
    ['X-Amz-Credential', `${input.accessKey}/${scope}`],
    ['X-Amz-Date', timestamp],
    ['X-Amz-Expires', String(input.lifetimeSeconds ?? SIGNED_LINK_LIFETIME_SECONDS)],
    ['X-Amz-SignedHeaders', 'host'],
  ].map(([name, value]) => `${encode(name)}=${encode(value)}`).join('&');

  const canonicalRequest = ['GET', path, query, `host:${input.host}\n`, 'host', 'UNSIGNED-PAYLOAD'].join('\n');
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    timestamp,
    scope,
    createHash('sha256').update(canonicalRequest).digest('hex'),
  ].join('\n');

  const signingKey = ['s3', 'aws4_request'].reduce(
    (key, part) => hmac(key, part),
    hmac(hmac(`AWS4${input.secretKey}`, day), input.region),
  );
  const signature = createHmac('sha256', signingKey).update(stringToSign).digest('hex');
  return `https://${input.host}${path}?${query}&X-Amz-Signature=${signature}`;
}
