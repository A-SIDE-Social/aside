import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  DeleteObjectsCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { config } from './config';
import { signGetUrl } from './lib/mediaSigning';

let s3Client: S3Client | null = null;

function getS3Client(): S3Client {
  if (!s3Client) {
    const options: any = {
      region: config.s3Region,
    };

    // Custom endpoint for S3-compatible providers (DigitalOcean Spaces, MinIO, etc.)
    if (config.s3Endpoint) {
      options.endpoint = config.s3Endpoint;
      options.forcePathStyle = false;
    }

    // Explicit credentials (required for DO Spaces, optional for AWS with IAM roles)
    if (config.s3AccessKey && config.s3SecretKey) {
      options.credentials = {
        accessKeyId: config.s3AccessKey,
        secretAccessKey: config.s3SecretKey,
      };
    }

    s3Client = new S3Client(options);
  }
  return s3Client;
}

// Voice captions are private objects. Only the authorized post-content
// endpoint reads them; never resolve them through the public CDN.
export async function putVoiceCaption(key: string, bytes: Buffer): Promise<void> {
  if (config.nodeEnv === 'development' || config.nodeEnv === 'test') {
    const fs = await import('fs/promises');
    const path = await import('path');
    const directory = path.join(__dirname, '../private-uploads');
    await fs.mkdir(directory, { recursive: true });
    await fs.writeFile(path.join(directory, path.basename(key)), bytes);
    return;
  }
  await getS3Client().send(new PutObjectCommand({
    Bucket: config.s3Bucket, Key: key, Body: bytes,
    ContentType: 'audio/mp4', ACL: 'private',
  }));
}

export async function readVoiceCaption(key: string): Promise<Buffer> {
  if (config.nodeEnv === 'development' || config.nodeEnv === 'test') {
    const fs = await import('fs/promises');
    const path = await import('path');
    return fs.readFile(path.join(__dirname, '../private-uploads', path.basename(key)));
  }
  const result = await getS3Client().send(new GetObjectCommand({ Bucket: config.s3Bucket, Key: key }));
  if (!result.Body || !result.ContentLength || result.ContentLength > 2097152) {
    throw new Error('Voice caption unavailable');
  }
  return Buffer.from(await result.Body.transformToByteArray());
}

/**
 * Generate a presigned PUT URL for uploading a file to object storage.
 * Works with AWS S3 and any S3-compatible provider (DO Spaces, MinIO, etc.)
 */
export async function getPresignedUploadUrl(
  key: string,
  contentType: string,
): Promise<string> {
  const client = getS3Client();
  const command = new PutObjectCommand({
    Bucket: config.s3Bucket,
    Key: key,
    ContentType: contentType,
    ACL: 'public-read',
  });
  return getSignedUrl(client, command, { expiresIn: 3600 });
}

/**
 * Presigned PUT for a **private** object (no public-read ACL).
 * Used for E2EE DM attachment ciphertext blobs, which should never
 * be exposed via the CDN or a public URL — recipient fetches via
 * [getPresignedDownloadUrl] with a short TTL.
 */
export async function getPresignedPrivateUploadUrl(
  key: string,
  contentType: string,
): Promise<string> {
  const client = getS3Client();
  const command = new PutObjectCommand({
    Bucket: config.s3Bucket,
    Key: key,
    ContentType: contentType,
    ACL: 'private',
  });
  return getSignedUrl(client, command, { expiresIn: 600 }); // 10 min
}

/**
 * Size in bytes of a stored object, or null when no such object exists.
 * Other storage failures throw so callers can tell them apart from "missing".
 */
export async function getStoredObjectSize(key: string): Promise<number | null> {
  try {
    const { ContentLength } = await getS3Client().send(
      new HeadObjectCommand({ Bucket: config.s3Bucket, Key: key }),
    );
    if (ContentLength === undefined) throw new Error('Storage returned no object size');
    return ContentLength;
  } catch (error: any) {
    if (error?.name === 'NotFound' || error?.$metadata?.httpStatusCode === 404) return null;
    throw error;
  }
}

/**
 * Presigned GET with a short TTL. For DM attachments we default to
 * 5 minutes — enough for the client to download once on receipt but
 * short enough that a leaked URL doesn't stay useful.
 */
export async function getPresignedDownloadUrl(
  key: string,
  ttlSeconds = 300,
): Promise<string> {
  const client = getS3Client();
  const command = new GetObjectCommand({
    Bucket: config.s3Bucket,
    Key: key,
  });
  return getSignedUrl(client, command, { expiresIn: ttlSeconds });
}

function storageHost(): string {
  if (config.s3Endpoint) return `${config.s3Bucket}.${new URL(config.s3Endpoint).host}`;
  return `${config.s3Bucket}.s3.${config.s3Region}.amazonaws.com`;
}

function signedMediaUrl(key: string): string {
  const host = storageHost();
  const url = signGetUrl({
    host,
    key,
    region: config.s3Region,
    accessKey: config.s3AccessKey,
    secretKey: config.s3SecretKey,
  });
  // The signature covers the storage host, and the CDN accepts it unchanged.
  return config.mediaSignedUrlsViaCdn && config.cdnUrl
    ? url.replace(`https://${host}`, config.cdnUrl)
    : url;
}

/** Avatars stay public: they appear before a connection exists. */
const isPublicMediaKey = (key: string): boolean => key.startsWith('avatar-');

/**
 * The object key behind a full media URL from this bucket, or null. Older rows
 * may store a full URL rather than a key, and those still need signing.
 */
export function storageKeyFromUrl(value: string): string | null {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  const path = decodeURIComponent(url.pathname.replace(/^\/+/, ''));
  const hosts = [storageHost(), config.cdnUrl && new URL(config.cdnUrl).host].filter(Boolean);
  if (hosts.includes(url.host)) return path || null;
  if (config.s3Endpoint && url.host === new URL(config.s3Endpoint).host) {
    const prefix = `${config.s3Bucket}/`;
    return path.startsWith(prefix) ? path.slice(prefix.length) || null : null;
  }
  return null;
}

/**
 * Resolve a stored media key to a URL the client can load.
 * With MEDIA_SIGNED_URLS on, everything except avatars gets a signed link.
 * Otherwise uses CDN_URL if configured, or builds the S3/Spaces direct URL.
 */
export function resolveStorageUrl(key: string): string {
  if (config.mediaSignedUrls && !isPublicMediaKey(key)) return signedMediaUrl(key);
  if (config.cdnUrl) {
    return `${config.cdnUrl}/${key}`;
  }
  // Direct S3/Spaces URL fallback
  if (config.s3Endpoint) {
    // DO Spaces: https://bucket.region.digitaloceanspaces.com/key
    return `${config.s3Endpoint}/${config.s3Bucket}/${key}`;
  }
  // AWS S3 direct URL
  return `https://${config.s3Bucket}.s3.${config.s3Region}.amazonaws.com/${key}`;
}

/**
 * Delete one or more objects from storage.
 * In dev mode, deletes from the local filesystem.
 */
export async function deleteStorageObjects(keys: string[]): Promise<void> {
  if (keys.length === 0) return;

  const isDev = config.nodeEnv === 'development' || config.nodeEnv === 'test';
  if (isDev) {
    const fs = await import('fs');
    const path = await import('path');
    const uploadsDir = path.join(__dirname, '../uploads');
    for (const key of keys) {
      const directory = key.startsWith('voice-captions/')
        ? path.join(__dirname, '../private-uploads') : uploadsDir;
      const filePath = path.join(directory, path.basename(key));
      try { fs.unlinkSync(filePath); } catch {}
      try { fs.unlinkSync(`${filePath}.meta`); } catch {}
    }
    return;
  }

  const client = getS3Client();
  const command = new DeleteObjectsCommand({
    Bucket: config.s3Bucket,
    Delete: {
      Objects: keys.map((k) => ({ Key: k })),
      Quiet: true,
    },
  });
  await client.send(command);
}
