import { config } from '../config';
import { LIMITS } from '../constants';
import { AppError } from '../middleware/errorHandler';
import { getStoredObjectSize } from '../storage';

/**
 * Reject a post whose uploaded media is missing or over the size limit.
 *
 * The limit applies to every item, whatever its declared media_type, so a
 * large file cannot pass by being labelled a photo. Run this before opening a
 * database transaction: it makes one storage request per item.
 *
 * Development and test uploads are local files, so there is nothing to check.
 */
export async function assertPostMediaWithinLimit(media: unknown): Promise<void> {
  if (config.nodeEnv === 'development' || config.nodeEnv === 'test') return;
  if (!Array.isArray(media) || media.length === 0) return;

  const sizes = await Promise.all(media.map(async (item: any) => {
    if (typeof item?.key !== 'string' || !item.key) {
      throw new AppError(400, 'Each media item needs an uploaded file');
    }
    try {
      return await getStoredObjectSize(item.key);
    } catch {
      throw new AppError(503, 'Could not check the uploaded file. Please try again.');
    }
  }));

  if (sizes.some((size) => size === null)) {
    throw new AppError(400, 'An uploaded file could not be found. Please try again.');
  }
  if (sizes.some((size) => (size as number) > LIMITS.maxPostMediaBytes)) {
    throw new AppError(413, 'Photos and videos can be up to 1 GB.');
  }
}
