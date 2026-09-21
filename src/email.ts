import { config } from './config';
import { AppError } from './middleware/errorHandler';
import { FailureReason } from './lib/failureReason';
import { measureStage } from './performance';

function deliveryError(error: unknown): AppError {
  // The Postmark SDK exposes numeric code/statusCode. Its message and the
  // inactive-recipient error's recipients array can contain private addresses.
  const provider = error as { code?: unknown; statusCode?: unknown } | null;
  let reason: FailureReason = 'email_provider_unavailable';
  if (provider?.statusCode === 401) reason = 'email_auth_failure';
  else if (provider?.statusCode === 429) reason = 'email_rate_limited';
  else if (provider?.statusCode === 422 && provider?.code === 406) {
    return new AppError(422, 'Unable to deliver a code to this email address. Try another address or contact support.', 'email_recipient_rejected');
  } else if (provider?.statusCode === 422) reason = 'email_request_rejected';
  return new AppError(503, 'Unable to send a login code right now. Please try again shortly.', reason);
}

/**
 * Send an OTP email via Postmark.
 *
 * In dev/test mode, the OTP is logged to the console instead of sending.
 */
export async function sendOtpEmail(email: string, code: string): Promise<void> {
  const isDev = config.nodeEnv === 'development' || config.nodeEnv === 'test';

  if (isDev) {
    console.log(`[OTP] ${email} → ${code}`);
    return;
  }

  if (!config.postmarkApiToken) {
    console.warn('[OTP] Email delivery unavailable', { reason: 'email_not_configured' });
    throw new AppError(503, 'Unable to send a login code right now. Please try again shortly.', 'email_not_configured');
  }

  await measureStage('otp_delivery', async () => {
    try {
      const { ServerClient } = await import('postmark');
      // SDK timeout is in seconds (its default is 180). Do not automatically
      // retry: a transport failure can occur after the provider accepted mail.
      const client = new ServerClient(config.postmarkApiToken, { timeout: 10 });

      await client.sendEmail({
        From: config.otpFromEmail,
        To: email,
        Subject: `${code} is your login code`,
        TextBody: [
          `Your login code is: ${code}`,
          '',
          'It expires in 10 minutes.',
          '',
          'If you didn\'t request this, you can safely ignore this email.',
        ].join('\n'),
        MessageStream: 'outbound',
      });
    } catch (error) {
      const failure = deliveryError(error);
      // Keep failures diagnosable when private metrics are disabled, without
      // serializing the provider error (which may contain addresses/tokens).
      console.warn('[OTP] Email delivery failed', { reason: failure.reason });
      throw failure;
    }
  });
}
