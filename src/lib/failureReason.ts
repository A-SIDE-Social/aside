// Only fixed categories may become metric labels. Never use exception messages,
// URLs, provider response bodies, or values supplied by a client.
export const failureReasons = [
  'refresh_invalid', 'refresh_unknown', 'refresh_revoked', 'refresh_idle_expired',
  'refresh_inactive_account', 'refresh_reused', 'refresh_superseded',
  'refresh_legacy_expired',
  'otp_registration_required', 'otp_registration_invalid', 'otp_invalid_or_expired',
  'otp_incorrect', 'otp_attempt_limit', 'key_identity_conflict', 'key_prekey_conflict',
  'key_legacy_recovery',
  'validation_failure', 'malformed_body', 'payload_too_large', 'unsupported_encoding',
  'request_aborted', 'auth_failure', 'forbidden', 'route_not_found', 'not_found',
  'method_not_allowed', 'rate_limited', 'client_error', 'internal_error',
  'email_not_configured', 'email_auth_failure', 'email_recipient_rejected',
  'email_request_rejected', 'email_rate_limited', 'email_provider_unavailable',
] as const;
export type FailureReason = typeof failureReasons[number];

export function defaultFailureReason(status: number, matched: boolean): FailureReason {
  switch (status) {
    case 400: case 422: return 'validation_failure';
    case 401: return 'auth_failure';
    case 403: return 'forbidden';
    case 404: return matched ? 'not_found' : 'route_not_found';
    case 405: return 'method_not_allowed';
    case 413: return 'payload_too_large';
    case 429: return 'rate_limited';
    default: return status >= 500 ? 'internal_error' : 'client_error';
  }
}
