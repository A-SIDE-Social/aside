import { HeadObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { LIMITS } from '../src/constants';
import { assertPostMediaWithinLimit } from '../src/lib/postMediaLimit';

jest.mock('../src/config', () => ({ config: {
  nodeEnv: 'production', s3Region: 'test-region', s3Bucket: 'media-test-bucket',
} }));

afterEach(() => jest.restoreAllMocks());

const sizeResponse = (ContentLength: number) => ({ ContentLength }) as never;

test('accepts media at the exact size limit and checks each stored object', async () => {
  const send = jest.spyOn(S3Client.prototype, 'send')
    .mockResolvedValue(sizeResponse(LIMITS.maxPostMediaBytes));
  await assertPostMediaWithinLimit([
    { key: 'a.mp4', media_type: 'video' },
    { key: 'b.jpeg', media_type: 'photo' },
  ]);
  expect(send).toHaveBeenCalledTimes(2);
  const command = send.mock.calls[0][0] as HeadObjectCommand;
  expect(command).toBeInstanceOf(HeadObjectCommand);
  expect(command.input).toEqual({ Bucket: 'media-test-bucket', Key: 'a.mp4' });
});

test.each(['video', 'photo'])('rejects an oversized file declared as %s', async (media_type) => {
  jest.spyOn(S3Client.prototype, 'send')
    .mockResolvedValue(sizeResponse(LIMITS.maxPostMediaBytes + 1));
  await expect(assertPostMediaWithinLimit([{ key: 'a.mp4', media_type }]))
    .rejects.toMatchObject({ statusCode: 413 });
});

test('rejects a post that references a missing upload', async () => {
  jest.spyOn(S3Client.prototype, 'send').mockRejectedValue(
    Object.assign(new Error('missing'), { name: 'NotFound' }) as never,
  );
  await expect(assertPostMediaWithinLimit([{ key: 'a.mp4', media_type: 'video' }]))
    .rejects.toMatchObject({ statusCode: 400 });
});

test('a storage failure is retryable and does not expose storage details', async () => {
  jest.spyOn(S3Client.prototype, 'send').mockRejectedValue(
    new Error('private-bucket-detail') as never,
  );
  const failure = assertPostMediaWithinLimit([{ key: 'a.mp4', media_type: 'video' }]);
  await expect(failure).rejects.toMatchObject({ statusCode: 503 });
  await expect(failure).rejects.not.toThrow('private-bucket-detail');
});

test.each([[{}], [{ key: 42 }], [{ key: '' }], [null]])(
  'rejects a media item without a usable key: %j',
  async (item) => {
    const send = jest.spyOn(S3Client.prototype, 'send');
    await expect(assertPostMediaWithinLimit([item])).rejects.toMatchObject({ statusCode: 400 });
    expect(send).not.toHaveBeenCalled();
  },
);

test.each([[undefined], [null], [[]]])('text posts make no storage request: %j', async (media) => {
  const send = jest.spyOn(S3Client.prototype, 'send');
  await assertPostMediaWithinLimit(media);
  expect(send).not.toHaveBeenCalled();
});
