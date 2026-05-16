import { Router } from 'express';
import { query } from '../db/pool';
import { config } from '../config';
import { FAMILY_MAX_MEMBERS, REVENUECAT_ENTITLEMENT, PROMO_DURATIONS } from '../constants';
import { asyncHandler, resolveMediaUrl } from '../helpers';
import { AppError } from '../middleware/errorHandler';

const router = Router();

// ---------------------------------------------------------------------------
// GET / — Current user's subscription status
// ---------------------------------------------------------------------------
router.get(
  '/status',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    const { rows } = await query(
      `SELECT u.subscription_status, u.subscription_plan, u.subscription_period_end,
              u.family_group_id, fg.owner_id AS family_owner_id
       FROM users u
       LEFT JOIN family_groups fg ON fg.id = u.family_group_id
       WHERE u.id = $1`,
      [userId],
    );

    if (rows.length === 0) throw new AppError(404, 'User not found');
    const user = rows[0];

    let family = null;
    if (user.family_group_id) {
      // Fetch family members
      const { rows: members } = await query(
        `SELECT u.id, u.display_name, u.avatar_url
         FROM users u
         WHERE u.family_group_id = $1
         ORDER BY u.created_at ASC`,
        [user.family_group_id],
      );
      for (const m of members) {
        if (m.avatar_url) m.avatar_url = resolveMediaUrl(m.avatar_url, req);
      }

      // Fetch owner info
      const { rows: ownerRows } = await query(
        'SELECT id, display_name, avatar_url FROM users WHERE id = $1',
        [user.family_owner_id],
      );
      const owner = ownerRows[0];
      if (owner?.avatar_url) owner.avatar_url = resolveMediaUrl(owner.avatar_url, req);

      family = {
        id: user.family_group_id,
        owner: owner || null,
        members,
        member_count: members.length,
        max_members: FAMILY_MAX_MEMBERS,
        is_owner: user.family_owner_id === userId,
      };
    }

    res.json({
      subscription: {
        status: user.subscription_status,
        plan: user.subscription_plan,
        period_end: user.subscription_period_end,
        family,
      },
    });
  }),
);

// ---------------------------------------------------------------------------
// POST /family/members — Add a member to family group
// ---------------------------------------------------------------------------
router.post(
  '/family/members',
  asyncHandler(async (req: any, res: any) => {
    const ownerId = req.user!.userId;
    const { user_id: targetUserId } = req.body;

    if (!targetUserId) throw new AppError(400, 'user_id is required');
    if (targetUserId === ownerId) throw new AppError(400, 'Cannot add yourself');

    // Verify caller has active family plan
    const { rows: ownerRows } = await query(
      'SELECT subscription_status, subscription_plan, family_group_id FROM users WHERE id = $1',
      [ownerId],
    );
    if (ownerRows.length === 0) throw new AppError(404, 'User not found');
    const owner = ownerRows[0];

    if (owner.subscription_plan !== 'pro_family') {
      throw new AppError(403, 'Family plan required to add members');
    }
    if (owner.subscription_status !== 'active') {
      throw new AppError(403, 'Active subscription required');
    }

    // Create family group if it doesn't exist
    let groupId = owner.family_group_id;
    if (!groupId) {
      const { rows: newGroup } = await query(
        'INSERT INTO family_groups (owner_id) VALUES ($1) RETURNING id',
        [ownerId],
      );
      groupId = newGroup[0].id;
      await query(
        'UPDATE users SET family_group_id = $2 WHERE id = $1',
        [ownerId, groupId],
      );
    }

    // Check member count
    const { rows: countRows } = await query(
      'SELECT COUNT(*)::int AS count FROM users WHERE family_group_id = $1',
      [groupId],
    );
    if (countRows[0].count >= FAMILY_MAX_MEMBERS) {
      throw new AppError(400, `Family group is full (max ${FAMILY_MAX_MEMBERS} members)`);
    }

    // Verify target user exists and is not in another family
    const { rows: targetRows } = await query(
      'SELECT id, family_group_id FROM users WHERE id = $1',
      [targetUserId],
    );
    if (targetRows.length === 0) throw new AppError(404, 'User not found');
    if (targetRows[0].family_group_id && targetRows[0].family_group_id !== groupId) {
      throw new AppError(400, 'User is already in another family group');
    }
    if (targetRows[0].family_group_id === groupId) {
      throw new AppError(400, 'User is already in your family group');
    }

    // Add member
    await query(
      `UPDATE users SET family_group_id = $2,
                       subscription_status = 'active',
                       subscription_plan = 'pro_family',
                       updated_at = NOW()
       WHERE id = $1`,
      [targetUserId, groupId],
    );

    res.json({ status: 'added' });
  }),
);

// ---------------------------------------------------------------------------
// DELETE /family/members/:userId — Remove a member from family group
// ---------------------------------------------------------------------------
router.delete(
  '/family/members/:userId',
  asyncHandler(async (req: any, res: any) => {
    const ownerId = req.user!.userId;
    const targetUserId = req.params.userId;

    if (targetUserId === ownerId) {
      throw new AppError(400, 'Owner cannot remove themselves. Cancel subscription instead.');
    }

    // Verify caller owns a family group
    const { rows: groupRows } = await query(
      'SELECT id FROM family_groups WHERE owner_id = $1',
      [ownerId],
    );
    if (groupRows.length === 0) throw new AppError(403, 'You do not own a family group');
    const groupId = groupRows[0].id;

    // Verify target is in this group
    const { rows: targetRows } = await query(
      'SELECT id FROM users WHERE id = $1 AND family_group_id = $2',
      [targetUserId, groupId],
    );
    if (targetRows.length === 0) throw new AppError(404, 'User not found in your family group');

    // Remove member — revert to free
    await query(
      `UPDATE users SET family_group_id = NULL,
                       subscription_status = 'free',
                       subscription_plan = 'free',
                       updated_at = NOW()
       WHERE id = $1`,
      [targetUserId],
    );

    res.json({ status: 'removed' });
  }),
);

// ---------------------------------------------------------------------------
// POST /family/leave — Member voluntarily leaves a family group
// ---------------------------------------------------------------------------
router.post(
  '/family/leave',
  asyncHandler(async (req: any, res: any) => {
    const userId = req.user!.userId;

    const { rows } = await query(
      'SELECT family_group_id FROM users WHERE id = $1',
      [userId],
    );
    if (rows.length === 0) throw new AppError(404, 'User not found');
    if (!rows[0].family_group_id) throw new AppError(400, 'You are not in a family group');

    // Check if user is the owner
    const { rows: groupRows } = await query(
      'SELECT owner_id FROM family_groups WHERE id = $1',
      [rows[0].family_group_id],
    );
    if (groupRows.length > 0 && groupRows[0].owner_id === userId) {
      throw new AppError(400, 'Owner cannot leave. Cancel your subscription instead.');
    }

    // Leave — revert to free
    await query(
      `UPDATE users SET family_group_id = NULL,
                       subscription_status = 'free',
                       subscription_plan = 'free',
                       updated_at = NOW()
       WHERE id = $1`,
      [userId],
    );

    res.json({ status: 'left' });
  }),
);

// ---------------------------------------------------------------------------
// POST /admin/grant — Grant promotional subscription (admin only)
// ---------------------------------------------------------------------------
router.post(
  '/admin/grant',
  asyncHandler(async (req: any, res: any) => {
    const callerId = req.user!.userId;

    // Check admin
    if (!config.adminUserIds.includes(callerId)) {
      throw new AppError(403, 'Admin access required');
    }

    const { user_id: targetUserId, duration } = req.body;
    if (!targetUserId) throw new AppError(400, 'user_id is required');
    if (!duration || !PROMO_DURATIONS.includes(duration)) {
      throw new AppError(400, `duration must be one of: ${PROMO_DURATIONS.join(', ')}`);
    }

    // Verify target exists
    const { rows: targetRows } = await query(
      'SELECT id FROM users WHERE id = $1',
      [targetUserId],
    );
    if (targetRows.length === 0) throw new AppError(404, 'User not found');

    // Grant via RevenueCat REST API
    if (config.revenuecatApiKey) {
      const rcRes = await fetch(
        `https://api.revenuecat.com/v1/subscribers/${targetUserId}/entitlements/${REVENUECAT_ENTITLEMENT}/promotional`,
        {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${config.revenuecatApiKey}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ duration }),
        },
      );

      if (!rcRes.ok) {
        const err = await rcRes.text();
        throw new AppError(502, `RevenueCat API error: ${err}`);
      }
    }

    // Also update locally (webhook will reinforce this, but for immediate effect)
    await query(
      `UPDATE users SET subscription_status = 'active',
                       subscription_plan = 'pro_individual',
                       updated_at = NOW()
       WHERE id = $1`,
      [targetUserId],
    );

    res.json({ status: 'granted', user_id: targetUserId, duration });
  }),
);

export default router;
