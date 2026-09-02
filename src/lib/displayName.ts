import { LIMITS } from '../constants';
import { AppError } from '../middleware/errorHandler';

const CONTROL_CHARACTERS = /[\u0000-\u001F\u007F-\u009F\u2028\u2029]/u;

/**
 * Validate and normalize the name shown throughout the app.
 *
 * Usernames are opaque internal identifiers; display_name is the public,
 * editable identity. Keep this normalization shared by registration and
 * profile edits so the two entry points cannot create different shapes.
 */
export function normalizeDisplayName(value: unknown): string {
  if (typeof value !== 'string') {
    throw new AppError(400, 'Name must be text');
  }

  const normalized = value.trim();
  const characterCount = Array.from(normalized).length;

  if (characterCount === 0) {
    throw new AppError(400, 'Name is required');
  }
  if (characterCount > LIMITS.maxDisplayNameLength) {
    throw new AppError(
      400,
      `Name must be ${LIMITS.maxDisplayNameLength} characters or fewer`,
    );
  }
  if (CONTROL_CHARACTERS.test(normalized)) {
    throw new AppError(
      400,
      'Name cannot contain line breaks or control characters',
    );
  }

  return normalized;
}
