import { config } from '../config';

const allowedOrigins = new Set(
  config.corsAllowedOrigins.map((origin) => origin.toLowerCase()),
);

export function isCorsOriginAllowed(origin: string | undefined): boolean {
  if (!origin) return true;
  return allowedOrigins.has(origin.toLowerCase());
}

export function corsOrigin(
  origin: string | undefined,
  callback: (err: Error | null, allow?: boolean) => void,
): void {
  callback(null, isCorsOriginAllowed(origin));
}
