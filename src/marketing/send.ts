// Broadcast send orchestration.
//
// Loads opted-in users, renders the per-recipient email, ships
// each one through Resend with bounded concurrency, records the
// outcome in `broadcasts`. One row per broadcast, NOT per
// recipient — Resend's own dashboard tracks per-recipient delivery
// + open + click; we just need to know "what did we send and how
// many landed."
//
// Rate-limit pacing: Resend's free / hobby tier caps at 2 requests
// per second. Earlier the broadcast ran 5 workers in parallel and
// got 429'd on roughly half the batch — the API errors were dropped
// silently before the failure-capture logging landed, which is how
// the first re-send showed 10/13/23. Serial sends with a small
// gap stay safely under the limit and finish a typical fanout
// (~25 users) in ~15 seconds.

import { Resend } from 'resend';
import { query } from '../db/pool';
import { config } from '../config';
import { allOptedInRecipients, type BroadcastRecipient } from './audience';
import { findTemplate } from './templates';

const PER_SEND_DELAY_MS = 600;

export interface BroadcastResult {
  broadcastId: string;
  recipientCount: number;
  sendCount: number;
  failureCount: number;
  failures: Array<{ email: string; error: string }>;
}

/// Sends the named template to every opted-in user. Inserts a
/// `broadcasts` audit row at the start, updates the counts when
/// done. If `dryRun` is true, audience is loaded + template is
/// rendered but no email is shipped + no broadcasts row is
/// written — useful for the admin UI's preview.
export async function sendBroadcast(opts: {
  templateKey: string;
  initiatedByUserId: string;
  dryRun?: boolean;
}): Promise<BroadcastResult> {
  const template = findTemplate(opts.templateKey);
  if (!template) {
    throw new Error(`Unknown template: ${opts.templateKey}`);
  }
  if (!opts.dryRun && !config.resendApiKey) {
    throw new Error(
      'RESEND_API_KEY is not set. Cannot send broadcasts in this environment.',
    );
  }

  const recipients = await allOptedInRecipients();

  // Render once per recipient to get a stable subject (used for the
  // broadcasts row) and to validate the template doesn't throw.
  const sample = recipients[0]
    ? template.render({
        recipientUserId: recipients[0].id,
        recipientName: recipients[0].display_name,
      })
    : template.render({ recipientUserId: '00000000-0000-0000-0000-000000000000', recipientName: 'Sample' });

  if (opts.dryRun) {
    return {
      broadcastId: 'dry-run',
      recipientCount: recipients.length,
      sendCount: 0,
      failureCount: 0,
      failures: [],
    };
  }

  // Persist the broadcast row up front so a crash mid-send still
  // leaves an audit trace.
  const { rows: bcRows } = await query(
    `INSERT INTO broadcasts
       (template_key, subject, initiated_by_user_id, recipient_count)
     VALUES ($1, $2, $3, $4)
     RETURNING id`,
    [template.key, sample.subject, opts.initiatedByUserId, recipients.length],
  );
  const broadcastId = bcRows[0].id;

  const resend = new Resend(config.resendApiKey);
  const failures: Array<{ email: string; error: string }> = [];
  let sendCount = 0;

  // Serial loop with a small gap so we stay under Resend's free-tier
  // 2/sec ceiling. No worker pool, no retries — if Resend rejects a
  // recipient for a real reason (suppression list, bad address) the
  // error gets persisted and we move on.
  for (let i = 0; i < recipients.length; i++) {
    const r = recipients[i];
    const rendered = template.render({
      recipientUserId: r.id,
      recipientName: r.display_name,
    });
    try {
      const { error } = await resend.emails.send({
        from: config.marketingFromEmail,
        to: [r.email],
        replyTo: config.marketingReplyToEmail,
        subject: rendered.subject,
        html: rendered.html,
        text: rendered.text,
        // Resend's standard one-click List-Unsubscribe header. Pairs
        // with the unsubscribe URL in the footer; some clients (Gmail,
        // Apple Mail) surface a one-tap unsubscribe button when this
        // header is present.
        headers: {
          'List-Unsubscribe': `<${config.unsubscribeBaseUrl}?token=${encodeURIComponent(makeUnsubscribeToken(r.id))}>`,
          'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
        },
      });
      if (error) {
        const msg = errorMessage(error);
        console.error(`[broadcast ${broadcastId}] FAIL ${r.email}: ${msg}`);
        failures.push({ email: r.email, error: msg });
      } else {
        sendCount++;
      }
    } catch (e) {
      const msg = errorMessage(e);
      console.error(`[broadcast ${broadcastId}] THROW ${r.email}: ${msg}`);
      failures.push({ email: r.email, error: msg });
    }
    // Pace requests. Skip the gap after the last one.
    if (i < recipients.length - 1) {
      await new Promise((resolve) => setTimeout(resolve, PER_SEND_DELAY_MS));
    }
  }

  // Stash the failure list on the broadcast row so the admin UI (or
  // a one-shot psql query) can read them after the fact without
  // grepping container logs. Truncate to the first 20 to keep the
  // row reasonably bounded.
  await query(
    `UPDATE broadcasts
        SET send_count = $1,
            failure_count = $2,
            completed_at = NOW(),
            variables = COALESCE(variables, '{}'::jsonb) || jsonb_build_object('failures', $4::jsonb)
      WHERE id = $3`,
    [
      sendCount,
      failures.length,
      broadcastId,
      JSON.stringify(failures.slice(0, 20)),
    ],
  );

  return {
    broadcastId,
    recipientCount: recipients.length,
    sendCount,
    failureCount: failures.length,
    failures,
  };
}

function errorMessage(e: unknown): string {
  if (e && typeof e === 'object' && 'message' in e) {
    return String((e as any).message);
  }
  return String(e);
}

// Re-export so call sites don't need to chase across modules.
export { allOptedInRecipients, type BroadcastRecipient };

import { makeUnsubscribeToken } from './unsubscribe-token';
