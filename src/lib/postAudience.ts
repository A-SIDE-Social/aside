import type { PoolClient } from 'pg';
import { LIMITS } from '../constants';
import { AppError } from '../middleware/errorHandler';

export const AUDIENCE_ALL_CONNECTIONS = 'all_connections';
export const AUDIENCE_LISTS = 'lists';

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface ResolvedPostAudience {
  type: typeof AUDIENCE_ALL_CONNECTIONS | typeof AUDIENCE_LISTS;
  listIds: string[];
  memberIds: string[];
}

/**
 * Resolve private-list selection into an immutable recipient snapshot.
 * Empty/omitted list ids retain the legacy "all mutual connections" scope.
 */
export async function resolvePostAudience(
  client: PoolClient,
  ownerId: string,
  rawListIds: unknown,
): Promise<ResolvedPostAudience> {
  if (rawListIds === undefined || rawListIds === null) {
    return { type: AUDIENCE_ALL_CONNECTIONS, listIds: [], memberIds: [] };
  }
  if (!Array.isArray(rawListIds)) {
    throw new AppError(400, 'group_ids must be an array');
  }

  const listIds = [...new Set(rawListIds)];
  if (listIds.length === 0) {
    return { type: AUDIENCE_ALL_CONNECTIONS, listIds: [], memberIds: [] };
  }
  if (listIds.length > LIMITS.maxGroups) {
    throw new AppError(
      400,
      `A post can use at most ${LIMITS.maxGroups} lists`,
    );
  }
  if (listIds.some((id) => typeof id !== 'string' || !UUID_PATTERN.test(id))) {
    throw new AppError(400, 'group_ids must contain valid ids');
  }

  const { rows: ownedLists } = await client.query<{ id: string }>(
    `SELECT id
       FROM groups
      WHERE user_id = $1
        AND id = ANY($2::uuid[])`,
    [ownerId, listIds],
  );
  if (ownedLists.length !== listIds.length) {
    throw new AppError(404, 'One or more lists were not found');
  }

  // A list can retain stale rows after a connection is removed. Snapshot only
  // people who are still active mutual connections at publication time.
  const { rows: members } = await client.query<{ user_id: string }>(
    `SELECT DISTINCT gm.member_user_id AS user_id
       FROM group_members gm
       JOIN users u
         ON u.id = gm.member_user_id
        AND u.deleted_at IS NULL
       JOIN follows outbound
         ON outbound.follower_id = $1
        AND outbound.followee_id = gm.member_user_id
       JOIN follows inbound
         ON inbound.follower_id = gm.member_user_id
        AND inbound.followee_id = $1
      WHERE gm.group_id = ANY($2::uuid[])`,
    [ownerId, listIds],
  );
  const memberIds = members.map((member) => member.user_id);
  if (memberIds.length === 0) {
    throw new AppError(400, 'Selected audience has no connected members');
  }

  return { type: AUDIENCE_LISTS, listIds: listIds as string[], memberIds };
}

/** SQL fragment shared by feed/profile queries. Caller supplies trusted SQL. */
export function postAudiencePredicate(
  postAlias: string,
  viewerParameter: string,
): string {
  return `(
    ${postAlias}.user_id = ${viewerParameter}
    OR ${postAlias}.audience_type = '${AUDIENCE_ALL_CONNECTIONS}'
    OR EXISTS (
      SELECT 1
        FROM post_audience_members pam
       WHERE pam.post_id = ${postAlias}.id
         AND pam.user_id = ${viewerParameter}
    )
  )`;
}
