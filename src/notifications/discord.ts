// Operator-side Discord webhook notifications. One sender today
// (new-user signups). The module is intentionally generic so
// additional event types — paid conversions, account deletions,
// etc. — can hang off the same `postToDiscord` helper without
// rebuilding the abstraction.
//
// Fail-quiet: if the webhook URL env var isn't set, every notify
// call is a no-op. If Discord is unreachable, the request is
// caught + logged but never thrown — registration (the call
// site) MUST NOT depend on Discord being up.

import { config } from '../config';

interface DiscordEmbed {
  title?: string;
  description?: string;
  /// Decimal color (e.g., 0x4A4A6E). Discord uses RGB integers,
  /// not hex strings, in the embed payload.
  color?: number;
  fields?: Array<{ name: string; value: string; inline?: boolean }>;
  /// ISO-8601 timestamp Discord renders in the embed footer.
  timestamp?: string;
  footer?: { text: string };
}

interface DiscordWebhookPayload {
  content?: string;
  username?: string;
  embeds?: DiscordEmbed[];
}

async function postToDiscord(
  url: string,
  payload: DiscordWebhookPayload,
): Promise<void> {
  if (!url) return; // unset env, treat as disabled
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '<no body>');
      console.warn(
        `Discord webhook returned ${res.status}: ${body}`,
      );
    }
  } catch (e) {
    // Common: DNS hiccup, Discord rate-limit, network blip. None
    // should ever propagate to the API caller.
    console.warn('Discord webhook failed:', e);
  }
}

/// Notify operators that a new user just completed registration.
/// Called from the signup transaction's success path AFTER COMMIT,
/// so we never notify about a row that ultimately rolled back.
export async function notifyNewUser(opts: {
  userId: string;
  displayName: string;
  email: string;
  inviteCode: string | null;
  inviterName?: string | null;
}): Promise<void> {
  const { userId, displayName, email, inviteCode, inviterName } = opts;

  const inviteLine = inviteCode
    ? inviterName
      ? `\`${inviteCode}\` (from **${inviterName}**)`
      : `\`${inviteCode}\``
    : '_none_';

  await postToDiscord(config.discordNewUserWebhookUrl, {
    username: 'A/SIDE',
    embeds: [
      {
        title: '🆕 New user signed up',
        // Iris/accent — same hex used in the app's accent color.
        color: 0x4a4a6e,
        fields: [
          { name: 'Name', value: displayName, inline: true },
          { name: 'Email', value: email, inline: true },
          { name: 'Invite code', value: inviteLine, inline: false },
          { name: 'User ID', value: `\`${userId}\``, inline: false },
        ],
        timestamp: new Date().toISOString(),
      },
    ],
  });
}
