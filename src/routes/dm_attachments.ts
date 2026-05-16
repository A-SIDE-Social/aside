// Phase 1g: E2EE DM attachment presigned URLs.
//
// The actual encryption + key management happens client-side (see
// mobile/rust/src/api/attachments.rs — ChaCha20-Poly1305 under a
// random per-blob file key). The server is a dumb blob store here:
// it hands out presigned PUT URLs for upload and presigned GET URLs
// for download, both scoped to a `dm/` key prefix. The ciphertext
// lives in the same DO Spaces bucket as feed media but with a
// `private` ACL so the CDN can't serve it.
//
// Authorization: any authenticated user can request an upload URL
// or download URL by key. The client embeds the key inside the
// E2EE message envelope, so only the intended recipient (who can
// decrypt the envelope) can usefully fetch the blob. Without the
// per-blob file key, downloaded bytes are opaque ciphertext.

import { Router } from 'express';
import { v4 as uuidv4 } from 'uuid';
import { asyncHandler } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import { config } from '../config';
import {
  getPresignedPrivateUploadUrl,
  getPresignedDownloadUrl,
} from '../storage';

const router = Router();

const isDev = () =>
  config.nodeEnv === 'development' || config.nodeEnv === 'test';

// POST /upload-url — Get a presigned PUT URL for uploading an
// encrypted attachment blob. Body: { content_type }.
// Response: { key, upload_url }. Client PUTs the ciphertext bytes
// to upload_url, then embeds `key` inside the E2EE message envelope.
router.post(
  '/upload-url',
  asyncHandler(async (req: any, res: any) => {
    const { content_type } = req.body;
    if (!content_type || typeof content_type !== 'string') {
      throw new AppError(400, 'content_type is required');
    }

    const key = `dm/${uuidv4()}`;
    // Most blobs are opaque ciphertext — client hint what kind of
    // decrypted payload it is (image/jpeg, video/mp4 etc) so the
    // server can set the right Content-Type on the object. Doesn't
    // affect decryption, just helps when recipients fetch + render.
    //
    // Dev/test: skip the real S3 round trip so credentials aren't
    // required to boot the API. The returned URL won't actually
    // accept uploads in dev, but that's fine — this env uses the
    // local uploads/ dir and dm-attachments isn't exercised by
    // mobile in dev E2E tests.
    let uploadUrl: string;
    if (isDev()) {
      const host = req.get('x-forwarded-host') || req.get('host');
      const proto = req.get('x-forwarded-proto') || req.protocol;
      uploadUrl = `${proto}://${host}/v1/posts/upload/${key.replace('/', '-')}`;
    } else {
      uploadUrl = await getPresignedPrivateUploadUrl(key, content_type);
    }

    res.json({ key, upload_url: uploadUrl });
  }),
);

// GET /:key — Return a presigned GET URL for downloading an
// encrypted attachment. 5-min TTL by default; if the URL leaks,
// it stops working quickly.
//
// The `:key` path catches the full `dm/<uuid>` — Express'
// wildcard-in-path semantics are fiddly, so we take the id as a
// separate param and reconstruct.
router.get(
  '/:id',
  asyncHandler(async (req: any, res: any) => {
    const { id } = req.params;
    if (!id || typeof id !== 'string' || !/^[a-f0-9-]+$/i.test(id)) {
      throw new AppError(400, 'invalid attachment id');
    }
    const key = `dm/${id}`;
    let downloadUrl: string;
    if (isDev()) {
      const host = req.get('x-forwarded-host') || req.get('host');
      const proto = req.get('x-forwarded-proto') || req.protocol;
      downloadUrl = `${proto}://${host}/v1/posts/upload/${id}`;
    } else {
      downloadUrl = await getPresignedDownloadUrl(key, 300);
    }
    res.json({ download_url: downloadUrl });
  }),
);

export default router;
