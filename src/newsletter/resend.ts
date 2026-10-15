import { NewsletterConfig } from './config';

// Pace this public flow to avoid exhausting the provider's shared request limit.
let nextRequestAt = 0;
export async function resendRequest<T>(key: string, path: string, method = 'GET', body?: unknown, idempotencyKey?: string): Promise<T | null> {
  for (let attempt = 0; attempt < 3; attempt++) {
    if (process.env.NODE_ENV !== 'test') {
      const wait = Math.max(0, nextRequestAt - Date.now());
      nextRequestAt = Date.now() + wait + 650;
      if (wait) await new Promise(resolve => setTimeout(resolve, wait));
    }
    const response = await fetch(`https://api.resend.com${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
        ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(10_000),
    });
    if (response.status === 404 && method === 'GET') return null;
    if (response.status === 429 && attempt < 2) {
      await new Promise(resolve => setTimeout(resolve, 1000 * (attempt + 1)));
      continue;
    }
    // Provider errors can contain recipient data. Do not put them in logs or pages.
    if (!response.ok) throw new Error(`Newsletter provider HTTP ${response.status}`);
    return await response.json() as T;
  }
  throw new Error('Newsletter provider rate limit');
}

export async function activateSubscriber(email: string, settings: NewsletterConfig): Promise<string | null> {
  const contact = await resendRequest<{ id: string; unsubscribed: boolean }>(settings.key, `/contacts/${encodeURIComponent(email)}`);
  // An editorial signup must never undo a global unsubscribe for another product.
  if (contact?.unsubscribed) return null;
  if (!contact) {
    const created = await resendRequest<{ id: string }>(settings.key, '/contacts', 'POST', {
      email,
      segments: [{ id: settings.segmentId }],
      topics: [{ id: settings.topicId, subscription: 'opt_in' }],
    });
    if (!created?.id) throw new Error('Newsletter contact creation failed');
    return created.id;
  }
  await resendRequest(settings.key, `/contacts/${contact.id}/segments/${settings.segmentId}`, 'POST');
  await resendRequest(settings.key, `/contacts/${contact.id}/topics`, 'PATCH', [
    { id: settings.topicId, subscription: 'opt_in' },
  ]);
  return contact.id;
}
