import { config } from './config';

/**
 * Send an OTP email via Postmark.
 *
 * In dev/test mode, the OTP is logged to the console instead of sending.
 */
export async function sendOtpEmail(email: string, code: string): Promise<void> {
  const isDev = config.nodeEnv === 'development' || config.nodeEnv === 'test' || !config.postmarkApiToken;

  if (isDev) {
    console.log(`[OTP] ${email} → ${code}`);
    return;
  }

  const { ServerClient } = await import('postmark');
  const client = new ServerClient(config.postmarkApiToken);

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
}
