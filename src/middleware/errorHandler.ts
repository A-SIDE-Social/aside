import { Request, Response, NextFunction } from 'express';
import { FailureReason } from '../lib/failureReason';

export class AppError extends Error {
  constructor(
    public statusCode: number,
    message: string,
    public reason?: FailureReason,
  ) {
    super(message);
    this.name = 'AppError';
  }
}

export function errorHandler(err: Error, _req: Request, res: Response, next: NextFunction): void {
  if (res.headersSent) { next(err); return; }
  if (err instanceof AppError) {
    res.locals.failureReason = err.reason;
    res.status(err.statusCode).json({ error: err.message });
    return;
  }

  // body-parser errors carry status + type; never reflect their message/body.
  // Do not trust arbitrary errors' status fields (e.g. provider HTTP failures).
  const bodyError = err as Error & { type?: string; status?: number };
  const bodyErrors: Record<string, [number, FailureReason, string]> = {
    'entity.parse.failed': [400, 'malformed_body', 'Invalid JSON body'],
    'request.size.invalid': [400, 'malformed_body', 'Invalid request body'],
    'request.aborted': [400, 'request_aborted', 'Request body was interrupted'],
    'entity.too.large': [413, 'payload_too_large', 'Request body is too large'],
    'encoding.unsupported': [415, 'unsupported_encoding', 'Unsupported request encoding'],
    'charset.unsupported': [415, 'unsupported_encoding', 'Unsupported request encoding'],
  };
  const knownBodyError = bodyError.type && Object.hasOwn(bodyErrors, bodyError.type)
    ? bodyErrors[bodyError.type] : undefined;
  if (knownBodyError && bodyError.status === knownBodyError[0]) {
    const [status, reason, message] = knownBodyError;
    res.locals.failureReason = reason;
    res.status(status).json({ error: message });
    return;
  }

  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error' });
}
