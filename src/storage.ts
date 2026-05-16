import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  DeleteObjectsCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { config } from './config';

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

/**
 * Resolve a stored media key to a public URL.
 * Uses CDN_URL if configured, otherwise builds the S3/Spaces direct URL.
 */
export function resolveStorageUrl(key: string): string {
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
      const filePath = path.join(uploadsDir, path.basename(key));
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
