import { Router } from 'express';
import crypto from 'crypto';
import { query } from '../db/pool';
import { config } from '../config';
import { PRODUCT_TO_PLAN } from '../constants';
import { asyncHandler } from '../helpers';
import { AppError } from '../middleware/errorHandler';

const router = Router();

function constantTimeTokenEqual(received: string, expected: string): boolean {
  const receivedHash = crypto.createHash('sha256').update(received).digest();
  const expectedHash = crypto.createHash('sha256').update(expected).digest();
  return crypto.timingSafeEqual(receivedHash, expectedHash);
}

// ---------------------------------------------------------------------------
// POST /revenuecat — RevenueCat server-to-server webhook
// ---------------------------------------------------------------------------
router.post(
  '/revenuecat',
  asyncHandler(async (req: any, res: any) => {
    // 1. Validate shared secret
    const authHeader = req.headers.authorization || '';
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
    if (
      !config.revenuecatWebhookSecret ||
      !constantTimeTokenEqual(token, config.revenuecatWebhookSecret)
    ) {
      throw new AppError(401, 'Unauthorized');
    }

    const event = req.body?.event;
    if (!event) {
      return res.status(400).json({ error: 'Missing event payload' });
    }

    const eventId: string = event.id;
    const eventType: string = event.type;
    const appUserId: string = event.app_user_id;
    const productId: string = event.product_id || '';
    const expirationAtMs: number | null = event.expiration_at_ms || null;

    if (!eventId || !eventType || !appUserId) {
      return res.status(400).json({ error: 'Missing required event fields' });
    }

    // 2. Idempotency check
    const { rows: existing } = await query(
      'SELECT id FROM revenuecat_webhook_events WHERE event_id = $1',
      [eventId],
    );
    if (existing.length > 0) {
      return res.json({ status: 'already_processed' });
    }

    // 3. Resolve user — appUserId is our backend user ID
    const { rows: users } = await query(
      'SELECT id, subscription_plan, family_group_id FROM users WHERE id = $1',
      [appUserId],
    );
    if (users.length === 0) {
      // Log the event even if user not found, to prevent reprocessing
      await logEvent(eventId, eventType, appUserId, req.body);
      return res.json({ status: 'user_not_found' });
    }

    const user = users[0];
    const plan = PRODUCT_TO_PLAN[productId] || user.subscription_plan;
    const periodEnd = expirationAtMs ? new Date(expirationAtMs) : null;

    // 4. Process event type
    switch (eventType) {
      case 'INITIAL_PURCHASE':
      case 'RENEWAL':
      case 'UNCANCELLATION': {
        await activateSubscription(appUserId, plan, periodEnd);
        break;
      }

      case 'CANCELLATION': {
        // User keeps access until period end; just mark as cancelled
        await query(
          `UPDATE users SET subscription_status = 'cancelled',
                           subscription_period_end = $2,
                           updated_at = NOW()
           WHERE id = $1`,
          [appUserId, periodEnd],
        );
        break;
      }

      case 'EXPIRATION':
      case 'BILLING_ISSUE': {
        await deactivateSubscription(appUserId);
        break;
      }

      case 'PRODUCT_CHANGE': {
        const newPlan = PRODUCT_TO_PLAN[productId] || 'pro_individual';
        const oldPlan = user.subscription_plan;

        // Update the plan type
        await query(
          `UPDATE users SET subscription_plan = $2,
                           subscription_period_end = $3,
                           updated_at = NOW()
           WHERE id = $1`,
          [appUserId, newPlan, periodEnd],
        );

        // If downgrading from family to individual, remove family members
        if (oldPlan === 'pro_family' && newPlan === 'pro_individual') {
          await removeFamilyMembers(appUserId);
        }
        break;
      }

      default:
        // Unknown event type — log but don't process
        break;
    }

    // 5. Log for idempotency
    await logEvent(eventId, eventType, appUserId, req.body);

    res.json({ status: 'ok' });
  }),
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function activateSubscription(userId: string, plan: string, periodEnd: Date | null) {
  await query(
    `UPDATE users SET subscription_status = 'active',
                     subscription_plan = $2,
                     subscription_period_end = $3,
                     updated_at = NOW()
     WHERE id = $1`,
    [userId, plan, periodEnd],
  );

  // If family plan, propagate to all family members
  if (plan === 'pro_family') {
    await propagateFamilyStatus(userId, 'active', 'pro_family');
  }
}

async function deactivateSubscription(userId: string) {
  const { rows } = await query(
    'SELECT subscription_plan, family_group_id FROM users WHERE id = $1',
    [userId],
  );
  const wasFamily = rows[0]?.subscription_plan === 'pro_family';

  await query(
    `UPDATE users SET subscription_status = 'expired',
                     subscription_plan = 'free',
                     subscription_period_end = NULL,
                     updated_at = NOW()
     WHERE id = $1`,
    [userId],
  );

  // If was family plan owner, revert all members
  if (wasFamily) {
    await removeFamilyMembers(userId);
  }
}

async function propagateFamilyStatus(ownerId: string, status: string, plan: string) {
  // Find the owner's family group
  const { rows } = await query(
    'SELECT id FROM family_groups WHERE owner_id = $1',
    [ownerId],
  );
  if (rows.length === 0) return;

  const groupId = rows[0].id;

  // Update all members (not the owner themselves)
  await query(
    `UPDATE users SET subscription_status = $2,
                     subscription_plan = $3,
                     updated_at = NOW()
     WHERE family_group_id = $1 AND id != $4`,
    [groupId, status, plan, ownerId],
  );
}

async function removeFamilyMembers(ownerId: string) {
  const { rows } = await query(
    'SELECT id FROM family_groups WHERE owner_id = $1',
    [ownerId],
  );
  if (rows.length === 0) return;

  const groupId = rows[0].id;

  // Revert all members to free
  await query(
    `UPDATE users SET subscription_status = 'free',
                     subscription_plan = 'free',
                     family_group_id = NULL,
                     updated_at = NOW()
     WHERE family_group_id = $1 AND id != $2`,
    [groupId, ownerId],
  );

  // Remove owner's family group reference too and delete the group
  await query('UPDATE users SET family_group_id = NULL WHERE id = $1', [ownerId]);
  await query('DELETE FROM family_groups WHERE id = $1', [groupId]);
}

async function logEvent(eventId: string, eventType: string, appUserId: string, payload: any) {
  await query(
    `INSERT INTO revenuecat_webhook_events (event_id, event_type, app_user_id, payload)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (event_id) DO NOTHING`,
    [eventId, eventType, appUserId, JSON.stringify(payload)],
  );
}

export default router;
