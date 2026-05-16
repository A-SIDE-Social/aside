// Audience selection for marketing broadcasts. v1 has one
// audience — every active opted-in user — but the function is
// shaped so future audiences (paid users only, recently-active,
// etc.) are an additional named export, not a query rewrite.

import { query } from '../db/pool';

export interface BroadcastRecipient {
  id: string;
  email: string;
  display_name: string;
}

/// All non-deleted users who haven't opted out of marketing email.
/// Returns nothing for users with a null email (legacy phone-only
/// accounts); broadcasts can't reach them anyway.
export async function allOptedInRecipients(): Promise<BroadcastRecipient[]> {
  const { rows } = await query(
    `SELECT id, email, display_name
       FROM users
      WHERE deleted_at IS NULL
        AND marketing_opt_in = true
        AND email IS NOT NULL
        AND email <> ''
      ORDER BY created_at ASC`,
  );
  return rows;
}
