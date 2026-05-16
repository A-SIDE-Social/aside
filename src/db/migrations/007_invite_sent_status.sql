-- Add 'sent' to the invite status enum so users can mark a code as shared.
-- 'sent' codes are still redeemable (treated like 'pending' by validate/redeem).
ALTER TABLE invites DROP CONSTRAINT IF EXISTS invites_status_check;
ALTER TABLE invites ADD CONSTRAINT invites_status_check
  CHECK (status IN ('pending', 'sent', 'used', 'expired', 'revoked'));
