import { Router } from 'express';
import { query, getClient } from '../db/pool';
import { asyncHandler } from '../helpers';
import { AppError } from '../middleware/errorHandler';
import type { PoolClient } from 'pg';
import { measureKeyUploadHandler, measureStage } from '../performance';

const router = Router();

function keyConflict(): AppError {
  return new AppError(409, 'An active encryption key set differs from this device. Recovery requires an explicit device change.', 'key_identity_conflict', 'key_bundle_conflict');
}

async function lockRegistry(client: PoolClient, userId: string): Promise<void> {
  // Lock even when no registry row exists yet. Upload and revocation must not
  // interleave and leave a newly uploaded identity without its prekeys.
  // The account key itself is not modified. NO KEY UPDATE still serializes
  // registry writers/revocation, but permits unrelated FK checks (KEY SHARE).
  await client.query('SELECT id FROM users WHERE id = $1 FOR NO KEY UPDATE', [userId]);
}

async function storePrekeys(
  client: PoolClient,
  userId: string,
  table: 'one_time_prekeys' | 'kyber_prekeys',
  keys: { id: number; pub: Buffer; sig?: Buffer }[],
): Promise<void> {
  if (!keys.length) return;
  if (new Set(keys.map(key => key.id)).size !== keys.length) {
    throw new AppError(400, 'Prekey IDs must be unique within a batch');
  }
  const kyber = table === 'kyber_prekeys';
  const { rows } = await client.query(
    `SELECT key_id, key_pub${kyber ? ', signature' : ''} FROM ${table}
     WHERE user_id = $1 AND key_id = ANY($2::int[])`,
    [userId, keys.map(key => key.id)],
  );
  const existing = new Map<number, any>(rows.map(row => [row.key_id, row]));
  // Account-level locking serializes material changes. Do not lock prekey rows:
  // peer fetches must remain free to consume them with SKIP LOCKED.
  for (const key of keys) {
    const old = existing.get(key.id);
    if (old && (!old.key_pub.equals(key.pub) || (kyber && !old.signature.equals(key.sig!)))) {
      throw new AppError(409, 'Prekey IDs conflict with previously registered material.',
        'key_prekey_conflict', 'key_prekey_conflict');
    }
  }
  const missing = keys.filter(key => !existing.has(key.id));
  if (!missing.length) return;
  await client.query(
    `INSERT INTO ${table} (user_id, key_id, key_pub${kyber ? ', signature' : ''})
     SELECT $1, batch.* FROM unnest($2::int[], $3::bytea[]${kyber ? ', $4::bytea[]' : ''}) AS batch`,
    [userId, missing.map(key => key.id), missing.map(key => key.pub),
      ...(kyber ? [missing.map(key => key.sig!)] : [])],
  );
  // Existing rows, including consumed_at, are never updated or resurrected.
}

// ---------- Push-notification tokens (pre-existing) ----------

// POST /token — Register a device token for push notifications
router.post(
  '/token',
  asyncHandler(async (req: any, res: any) => {
    const userId = (req as any).user?.userId;
    const { token, platform } = req.body;

    if (!token || typeof token !== 'string') {
      throw new AppError(400, 'token is required');
    }
    if (!platform || !['ios', 'android'].includes(platform)) {
      throw new AppError(400, 'platform must be ios or android');
    }

    // Upsert: if token exists (maybe from another user on same device), update user_id
    await query(
      `INSERT INTO device_tokens (user_id, token, platform)
       VALUES ($1, $2, $3)
       ON CONFLICT (token) DO UPDATE SET user_id = $1, updated_at = now()`,
      [userId, token, platform],
    );

    res.json({ message: 'Token registered' });
  }),
);

// DELETE /token — Unregister a device token (on logout)
router.delete(
  '/token',
  asyncHandler(async (req: any, res: any) => {
    const userId = (req as any).user?.userId;
    const { token } = req.body;

    if (!token || typeof token !== 'string') {
      throw new AppError(400, 'token is required');
    }

    await query(
      'DELETE FROM device_tokens WHERE token = $1 AND user_id = $2',
      [token, userId],
    );

    res.json({ message: 'Token unregistered' });
  }),
);

// ---------- E2EE key registry (Phase 1c) ----------

/**
 * Decodes a base64 string, asserts the byte length, and returns a
 * Buffer ready to bind to a bytea column. Throws 400 with a clear
 * message on bad input — these endpoints are fed directly from the
 * Dart client so shape bugs are loud early.
 */
function decodeBytes(
  value: unknown,
  expected: number,
  name: string,
): Buffer {
  if (typeof value !== 'string' || value.length === 0) {
    throw new AppError(400, `${name} must be a non-empty base64 string`);
  }
  const buf = Buffer.from(value, 'base64');
  if (buf.length !== expected) {
    throw new AppError(
      400,
      `${name} must decode to ${expected} bytes (got ${buf.length})`,
    );
  }
  return buf;
}

function validateKeyId(value: unknown, name: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 1) {
    throw new AppError(400, `${name} must be a positive integer`);
  }
  // Postgres integer is 32-bit signed. libsignal's ids are u32 client-side,
  // so cap at 2^31-1 on the wire — we've never shipped u32 ids anyway.
  if (value > 2147483647) {
    throw new AppError(400, `${name} exceeds 2^31-1`);
  }
  return value;
}

// Kyber prekey public keys are ~1568 bytes for Kyber1024. Rather
// than hard-coding an exact count that would break if libsignal's
// encoding shifts, we accept a conservative range — far below any
// legitimate Kyber variant yet far above any classical keypair.
const KYBER_PUB_MIN = 1500;
const KYBER_PUB_MAX = 1700;

function decodeKyberPub(value: unknown, name: string): Buffer {
  if (typeof value !== 'string' || value.length === 0) {
    throw new AppError(400, `${name} must be a non-empty base64 string`);
  }
  const buf = Buffer.from(value, 'base64');
  if (buf.length < KYBER_PUB_MIN || buf.length > KYBER_PUB_MAX) {
    throw new AppError(
      400,
      `${name} must decode to ${KYBER_PUB_MIN}–${KYBER_PUB_MAX} bytes ` +
        `(got ${buf.length}) — expected a Kyber1024 public key`,
    );
  }
  return buf;
}

// POST /keys/upload — First-run upload of a full key bundle.
//
// Body:
//   { identity_key_pub: "base64",
//     signed_prekey: { id, public: "b64", signature: "b64" },
//     one_time_prekeys: [{ id, public: "b64" }, ...],
//     kyber_prekeys:    [{ id, public: "b64", signature: "b64" }, ...] }
//
// Reconciles an identical active identity and signed prekey without replacing
// either. Conflicting material remains a 409; retries never revoke keys.
// New registrations require Kyber prekeys. An existing identity may reconcile
// a depleted local bundle without resetting any consumed rows.
router.post(
  '/keys/upload',
  asyncHandler(measureKeyUploadHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    if (req.body.owner_user_id !== undefined && req.body.owner_user_id !== userId) {
      throw new AppError(403, 'Encryption keys belong to a different account');
    }
    if (req.body.existing_only !== undefined && typeof req.body.existing_only !== 'boolean') {
      throw new AppError(400, 'existing_only must be a boolean');
    }
    const {
      identity_key_pub,
      signed_prekey,
      one_time_prekeys,
      kyber_prekeys,
    } = req.body;

    const identityPub = decodeBytes(identity_key_pub, 33, 'identity_key_pub');

    if (!signed_prekey || typeof signed_prekey !== 'object') {
      throw new AppError(400, 'signed_prekey is required');
    }
    const spkId = validateKeyId(signed_prekey.id, 'signed_prekey.id');
    const spkPub = decodeBytes(signed_prekey.public, 33, 'signed_prekey.public');
    const spkSig = decodeBytes(signed_prekey.signature, 64, 'signed_prekey.signature');

    if (!Array.isArray(one_time_prekeys)) {
      throw new AppError(400, 'one_time_prekeys must be an array');
    }
    if (one_time_prekeys.length > 200) {
      throw new AppError(400, 'one_time_prekeys batch size limited to 200');
    }
    const otpks = one_time_prekeys.map((k: any, i: number) => ({
      id: validateKeyId(k?.id, `one_time_prekeys[${i}].id`),
      pub: decodeBytes(k?.public, 33, `one_time_prekeys[${i}].public`),
    }));

    if (!Array.isArray(kyber_prekeys)) {
      throw new AppError(
        400,
        'kyber_prekeys must be an array',
      );
    }
    if (kyber_prekeys.length > 100) {
      throw new AppError(400, 'kyber_prekeys batch size limited to 100');
    }
    const kpks = kyber_prekeys.map((k: any, i: number) => ({
      id: validateKeyId(k?.id, `kyber_prekeys[${i}].id`),
      pub: decodeKyberPub(k?.public, `kyber_prekeys[${i}].public`),
      sig: decodeBytes(k?.signature, 64, `kyber_prekeys[${i}].signature`),
    }));

    const client = await measureStage('key_upload_pool', () => getClient());
    try {
      await client.query('BEGIN');
      await measureStage('key_upload_lock', () => lockRegistry(client, userId));

      await measureStage('key_upload_registry', async () => {
        const existing = await client.query(
          `SELECT identity_key_pub, signed_prekey_id, signed_prekey_pub, signed_prekey_sig
           FROM device_keys WHERE user_id = $1 AND revoked_at IS NULL FOR UPDATE`,
          [userId],
        );
        if (existing.rows.length > 0) {
          const old = existing.rows[0];
          if (!old.identity_key_pub.equals(identityPub) || old.signed_prekey_id !== spkId ||
              !old.signed_prekey_pub.equals(spkPub) || !old.signed_prekey_sig.equals(spkSig)) {
            throw keyConflict();
          }
        } else {
          // A legacy local identity has no recorded owner. It may only reconcile
          // with this account's existing registry, not silently register elsewhere.
          if (req.body.existing_only === true) {
            throw new AppError(409, 'Existing local keys require manual account recovery', 'key_legacy_recovery', 'key_recovery_required');
          }
          if (!kpks.length) {
            throw new AppError(400, 'Initial upload requires Kyber prekeys', undefined, 'key_bundle_incomplete');
          }
          await client.query(
            `INSERT INTO device_keys
               (user_id, identity_key_pub, signed_prekey_id, signed_prekey_pub, signed_prekey_sig)
             VALUES ($1, $2, $3, $4, $5)`,
            [userId, identityPub, spkId, spkPub, spkSig],
          );
        }
      });

      await measureStage('key_upload_one_time', () => storePrekeys(client, userId, 'one_time_prekeys', otpks));
      await measureStage('key_upload_kyber', () => storePrekeys(client, userId, 'kyber_prekeys', kpks));

      await measureStage('key_upload_commit', () => client.query('COMMIT'));
      res.json({
        message: 'Keys uploaded',
        one_time_prekey_count: otpks.length,
        kyber_prekey_count: kpks.length,
      });
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  })),
);

// Read-only allocation bounds for this account's unchanged identity + signed
// prekey. These are key-protocol values, never diagnostic/metric labels. No
// stored public/private key or consumed row is changed by this operation.
router.post('/keys/prekey-allocation', asyncHandler(async (req: any, res: any) => {
  const userId = req.user!.userId;
  if (req.body.owner_user_id !== userId) throw new AppError(403, 'Encryption keys belong to a different account');
  const identity = decodeBytes(req.body.identity_key_pub, 33, 'identity_key_pub');
  const signed = req.body.signed_prekey;
  const id = validateKeyId(signed?.id, 'signed_prekey.id');
  const pub = decodeBytes(signed?.public, 33, 'signed_prekey.public');
  const sig = decodeBytes(signed?.signature, 64, 'signed_prekey.signature');
  const client = await getClient();
  try {
    await client.query('BEGIN');
    await lockRegistry(client, userId);
    const { rows } = await client.query(
      `SELECT identity_key_pub, signed_prekey_id, signed_prekey_pub, signed_prekey_sig
       FROM device_keys WHERE user_id = $1 AND revoked_at IS NULL`, [userId]);
    const old = rows[0];
    if (!old || !old.identity_key_pub.equals(identity) || old.signed_prekey_id !== id ||
        !old.signed_prekey_pub.equals(pub) || !old.signed_prekey_sig.equals(sig)) throw keyConflict();
    const { rows: bounds } = await client.query(
      `SELECT (SELECT COALESCE(MAX(key_id), 0) FROM one_time_prekeys WHERE user_id = $1) AS one_time_floor,
              (SELECT COALESCE(MAX(key_id), 0) FROM kyber_prekeys WHERE user_id = $1) AS kyber_floor`, [userId]);
    await client.query('COMMIT');
    res.json(bounds[0]);
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { client.release(); }
}));

// POST /keys/replenish — Add more OTPKs and/or Kyber prekeys to an
// existing active key set. Both arrays are optional but at least
// one must be non-empty. Identical retries are idempotent; conflicting
// material is rejected without changing consumed flags.
//
// Body: { one_time_prekeys?: [...], kyber_prekeys?: [...] }
router.post(
  '/keys/replenish',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { one_time_prekeys, kyber_prekeys } = req.body;
    if (req.body.owner_user_id !== undefined && req.body.owner_user_id !== userId) {
      throw new AppError(403, 'Encryption keys belong to a different account');
    }
    const expectedIdentity = req.body.identity_key_pub === undefined ? null
      : decodeBytes(req.body.identity_key_pub, 33, 'identity_key_pub');

    const hasOtpks = Array.isArray(one_time_prekeys) && one_time_prekeys.length > 0;
    const hasKpks = Array.isArray(kyber_prekeys) && kyber_prekeys.length > 0;

    if (!hasOtpks && !hasKpks) {
      throw new AppError(
        400,
        'one_time_prekeys or kyber_prekeys must be a non-empty array',
      );
    }

    let otpks: { id: number; pub: Buffer }[] = [];
    if (hasOtpks) {
      if (one_time_prekeys.length > 200) {
        throw new AppError(400, 'one_time_prekeys batch size limited to 200');
      }
      otpks = one_time_prekeys.map((k: any, i: number) => ({
        id: validateKeyId(k?.id, `one_time_prekeys[${i}].id`),
        pub: decodeBytes(k?.public, 33, `one_time_prekeys[${i}].public`),
      }));
    }

    let kpks: { id: number; pub: Buffer; sig: Buffer }[] = [];
    if (hasKpks) {
      if (kyber_prekeys.length > 100) {
        throw new AppError(400, 'kyber_prekeys batch size limited to 100');
      }
      kpks = kyber_prekeys.map((k: any, i: number) => ({
        id: validateKeyId(k?.id, `kyber_prekeys[${i}].id`),
        pub: decodeKyberPub(k?.public, `kyber_prekeys[${i}].public`),
        sig: decodeBytes(k?.signature, 64, `kyber_prekeys[${i}].signature`),
      }));
    }

    const client = await getClient();
    try {
      await client.query('BEGIN');
      await lockRegistry(client, userId);

      const keysRow = await client.query(
        `SELECT id, identity_key_pub FROM device_keys
         WHERE user_id = $1 AND revoked_at IS NULL`,
        [userId],
      );
      if (keysRow.rows.length === 0) {
        await client.query('ROLLBACK');
        throw new AppError(
          404,
          'no active key set; POST /keys/upload before replenishing',
        );
      }
      if (expectedIdentity && !keysRow.rows[0].identity_key_pub.equals(expectedIdentity)) {
        throw keyConflict();
      }

      await storePrekeys(client, userId, 'one_time_prekeys', otpks);
      await storePrekeys(client, userId, 'kyber_prekeys', kpks);

      await client.query('COMMIT');
      res.json({
        message: 'Prekeys added',
        one_time_prekeys_added: otpks.length,
        kyber_prekeys_added: kpks.length,
      });
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }),
);

// POST /keys/rotate-signed — Replace the signed prekey with a fresh one.
//
// Body: { signed_prekey: { id, public: "b64", signature: "b64" } }
router.post(
  '/keys/rotate-signed',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;
    const { signed_prekey } = req.body;

    if (!signed_prekey || typeof signed_prekey !== 'object') {
      throw new AppError(400, 'signed_prekey is required');
    }
    const spkId = validateKeyId(signed_prekey.id, 'signed_prekey.id');
    const spkPub = decodeBytes(signed_prekey.public, 33, 'signed_prekey.public');
    const spkSig = decodeBytes(
      signed_prekey.signature,
      64,
      'signed_prekey.signature',
    );

    const { rowCount } = await query(
      `UPDATE device_keys
       SET signed_prekey_id = $1,
           signed_prekey_pub = $2,
           signed_prekey_sig = $3,
           rotated_at = now()
       WHERE user_id = $4 AND revoked_at IS NULL`,
      [spkId, spkPub, spkSig, userId],
    );
    if (rowCount === 0) {
      throw new AppError(
        404,
        'no active key set; POST /keys/upload before rotating',
      );
    }

    res.json({ message: 'Signed prekey rotated', id: spkId });
  }),
);

// POST /revoke — Mark the current active key set revoked and drop
// its OTPKs. Clients call this on sign-out. The revoked device_keys
// row is kept as history (for audit / key-change anomaly detection),
// but OTPKs are deleted so a subsequent re-upload can reuse their
// key_id namespace without a unique-constraint collision. The OTPKs
// were unreachable anyway — /keybundle requires an active row.
router.post(
  '/revoke',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    const client = await getClient();
    try {
      await client.query('BEGIN');
      await lockRegistry(client, userId);

      const { rowCount } = await client.query(
        `UPDATE device_keys
         SET revoked_at = now()
         WHERE user_id = $1 AND revoked_at IS NULL`,
        [userId],
      );

      // Clean up OTPKs + Kyber regardless — they're tied to the
      // identity we just revoked (or, if rowCount was 0, to a
      // long-gone one). Same reasoning as the OTPK cleanup:
      // preserves their key_id namespace for the next upload.
      await client.query(
        'DELETE FROM one_time_prekeys WHERE user_id = $1',
        [userId],
      );
      await client.query(
        'DELETE FROM kyber_prekeys WHERE user_id = $1',
        [userId],
      );

      await client.query('COMMIT');

      if (rowCount === 0) {
        return res.json({ message: 'No active keys to revoke' });
      }
      res.json({ message: 'Keys revoked' });
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }),
);

export default router;
