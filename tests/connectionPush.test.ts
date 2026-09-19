jest.mock('../src/db/pool', () => ({ query: jest.fn(), getClient: jest.fn() }));
jest.mock('../src/firebase', () => ({
  sendPush: jest.fn(), getTokensForUsers: jest.fn(), filterByPushThrottle: jest.fn(), stampPushSent: jest.fn(),
}));
import { query } from '../src/db/pool';
import { sendPush, getTokensForUsers, filterByPushThrottle, stampPushSent } from '../src/firebase';
import { pushConnection } from '../src/lib/connections';

const result = { self: false, isNew: true, isMutual: false, callerId: 'caller', targetId: 'target', callerName: 'Friend', follow: {} };

afterEach(() => jest.restoreAllMocks());
beforeEach(() => jest.clearAllMocks());

test('push failure cannot turn a committed request into an error response', async () => {
  jest.spyOn(console, 'warn').mockImplementation(() => {});
  (query as jest.Mock).mockResolvedValue({ rows: [{ enabled: true }] });
  (filterByPushThrottle as jest.Mock).mockResolvedValue(['target']);
  (getTokensForUsers as jest.Mock).mockResolvedValue(['device-token']);
  (sendPush as jest.Mock).mockRejectedValue(new Error('push service unavailable'));
  await expect(pushConnection(result)).resolves.toBeUndefined();
  expect(stampPushSent).not.toHaveBeenCalled();
});

test('failure reading push preferences also leaves the committed request successful', async () => {
  jest.spyOn(console, 'warn').mockImplementation(() => {});
  (query as jest.Mock).mockRejectedValue(new Error('temporary database disconnect'));
  await expect(pushConnection(result)).resolves.toBeUndefined();
  expect(sendPush).not.toHaveBeenCalled();
});
