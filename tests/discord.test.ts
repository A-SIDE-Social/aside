/**
 * Unit tests for the Discord webhook helper.
 *
 * Verifies:
 *   1. No-op when DISCORD_NEW_USER_WEBHOOK_URL is unset (registration
 *      stays untouched on operators who haven't configured it).
 *   2. Correct payload shape (embed title + fields) when configured.
 *   3. Network failure is swallowed (registration must never depend
 *      on Discord being reachable).
 */

import { notifyNewUser } from '../src/notifications/discord';
import { config } from '../src/config';

describe('notifyNewUser', () => {
  let originalUrl: string;
  let originalFetch: typeof fetch;
  let calls: Array<{ url: string; init: RequestInit }>;

  beforeEach(() => {
    originalUrl = config.discordNewUserWebhookUrl;
    originalFetch = global.fetch;
    calls = [];
    // Default mock: succeed with 204 (Discord's success status).
    global.fetch = (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response(null, { status: 204 });
    }) as any;
  });

  afterEach(() => {
    config.discordNewUserWebhookUrl = originalUrl;
    global.fetch = originalFetch;
  });

  test('no-op when webhook URL is unset', async () => {
    config.discordNewUserWebhookUrl = '';
    await notifyNewUser({
      userId: 'u1',
      displayName: 'Test',
      email: 'test@example.com',
      inviteCode: null,
    });
    expect(calls).toHaveLength(0);
  });

  test('posts an embed to the configured URL', async () => {
    config.discordNewUserWebhookUrl = 'https://discord.test/webhook';
    await notifyNewUser({
      userId: 'u-abc',
      displayName: 'Maya',
      email: 'maya@example.com',
      inviteCode: 'WREN-7K2P',
      inviterName: 'Alex',
    });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe('https://discord.test/webhook');
    expect(calls[0].init.method).toBe('POST');

    const body = JSON.parse(calls[0].init.body as string);
    expect(body.username).toBe('A/SIDE');
    expect(body.embeds).toHaveLength(1);
    const embed = body.embeds[0];
    expect(embed.title).toContain('New user signed up');
    expect(embed.color).toBe(0x4a4a6e);

    // Field-level assertions — we ship Name + Email + Invite + ID.
    const fieldsByName = Object.fromEntries(
      embed.fields.map((f: any) => [f.name, f.value]),
    );
    expect(fieldsByName.Name).toBe('Maya');
    expect(fieldsByName.Email).toBe('maya@example.com');
    expect(fieldsByName['Invite code']).toContain('WREN-7K2P');
    expect(fieldsByName['Invite code']).toContain('Alex');
    expect(fieldsByName['User ID']).toContain('u-abc');

    // Timestamp is an ISO-8601 string Discord renders in the footer.
    expect(typeof embed.timestamp).toBe('string');
    expect(() => new Date(embed.timestamp).toISOString()).not.toThrow();
  });

  test('renders "_none_" for the invite-code field when no code was used', async () => {
    config.discordNewUserWebhookUrl = 'https://discord.test/webhook';
    await notifyNewUser({
      userId: 'u1',
      displayName: 'Direct Signup',
      email: 'direct@example.com',
      inviteCode: null,
    });
    const body = JSON.parse(calls[0].init.body as string);
    const inviteField = body.embeds[0].fields.find(
      (f: any) => f.name === 'Invite code',
    );
    expect(inviteField.value).toBe('_none_');
  });

  test('swallows network errors (does not throw)', async () => {
    config.discordNewUserWebhookUrl = 'https://discord.test/webhook';
    global.fetch = (async () => {
      throw new Error('network down');
    }) as any;
    // The thing under test: the call resolves successfully despite
    // fetch throwing. Registration's hot path can `await` this
    // without a try/catch and never blow up.
    await expect(
      notifyNewUser({
        userId: 'u1',
        displayName: 'Test',
        email: 'test@example.com',
        inviteCode: null,
      }),
    ).resolves.toBeUndefined();
  });

  test('swallows non-2xx responses', async () => {
    config.discordNewUserWebhookUrl = 'https://discord.test/webhook';
    global.fetch = (async () => {
      return new Response('rate limited', { status: 429 });
    }) as any;
    await expect(
      notifyNewUser({
        userId: 'u1',
        displayName: 'Test',
        email: 'test@example.com',
        inviteCode: null,
      }),
    ).resolves.toBeUndefined();
  });
});
