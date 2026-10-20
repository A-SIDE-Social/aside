import { PutObjectCommand, GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { putVoiceCaption, readVoiceCaption } from '../src/storage';

jest.mock('../src/config', () => ({ config: {
  nodeEnv: 'production', s3Region: 'test-region', s3Bucket: 'private-test-bucket',
} }));

afterEach(() => jest.restoreAllMocks());

test('production voice uploads explicitly use private objects', async () => {
  const send = jest.spyOn(S3Client.prototype, 'send').mockResolvedValue({} as never);
  const bytes = Buffer.from('audio fixture');
  await putVoiceCaption('voice-captions/test.m4a', bytes);
  const command = send.mock.calls[0][0] as PutObjectCommand;
  expect(command).toBeInstanceOf(PutObjectCommand);
  expect(command.input).toEqual({
    Bucket: 'private-test-bucket', Key: 'voice-captions/test.m4a',
    Body: bytes, ContentType: 'audio/mp4', ACL: 'private',
  });
});

test('production reads audio without generating a public URL', async () => {
  const send = jest.spyOn(S3Client.prototype, 'send').mockResolvedValue({
    ContentLength: 3, Body: { transformToByteArray: async () => new Uint8Array([1, 2, 3]) },
  } as never);
  expect(await readVoiceCaption('voice-captions/test.m4a')).toEqual(Buffer.from([1, 2, 3]));
  expect(send.mock.calls[0][0]).toBeInstanceOf(GetObjectCommand);
});

test('oversized stored objects are rejected before downloading their body', async () => {
  const read = jest.fn();
  jest.spyOn(S3Client.prototype, 'send').mockResolvedValue({
    ContentLength: 2097153, Body: { transformToByteArray: read },
  } as never);
  await expect(readVoiceCaption('voice-captions/test.m4a')).rejects.toThrow('unavailable');
  expect(read).not.toHaveBeenCalled();
});
