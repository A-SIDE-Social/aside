# Messaging on a replacement device

Version 1.8 adds an explicit recovery path when the active encryption
registration differs from the signed-in device. In Messages, choose **Move
messaging here**, read the warning, request an email code and confirm the
change. Ordinary retries never revoke a conflicting identity.

This changes the public-key registration, not message history. The current
device keeps its private keys and cached messages. Older encrypted messages
may remain unreadable on a replacement device. It is not a backup or
multi-device synchronization, and does not erase copies or immediately end
every established session on another device. Contacts using older app versions
may need to update for automatic identity refresh and group-key redistribution.

## Protocol boundaries

- Code issuance and confirmation require an authenticated account and its live
  login-session credential. A separately signed, ten-minute ticket binds the
  account, confirming session, proposed public bundle and registry generation.
- Device-change and login codes have different purposes. They share the
  existing resend cooldown and bounded guess limit, but cannot replace one
  another. The email identifies the device-change action.
- Confirmation installs the new registry and its public prekeys in one
  transaction. The old registration is revoked only on success. Concurrent or
  interrupted exact retries do not resurrect consumed prekeys. A ticket cannot
  restore a registration after another change.
- Recovered registrations retain the confirming session's ownership even if
  that session is deleted. Old clients' sign-out cleanup cannot revoke a newer
  recovered registration. Deliberate sign-out revokes the owning registration
  before ending its login session; local sign-out still completes offline.
- Eligible peers can read the current public identity without consuming a
  prekey. Updated clients check before sending and establish a new session
  when the identity changes, retaining the existing identity-change notice.
  Encrypted group epochs advance once per committed transfer, prompting fresh
  sender-key distribution. Peer bundle reads cannot mix registry generations.

The new protocol fields are functional account/crypto state, not diagnostic
labels. Do not log request bodies, tickets, credentials, email addresses or
public/private key material. Existing aggregate failure categories remain
fixed. Published implementation is not an independent security audit.

## Self-hosted upgrade

Apply `032_key_registry_session.sql` before serving this API version. It adds
nullable session ownership to `device_keys` and purpose-bound email codes.
Existing registrations and login codes retain their legacy behavior until an
explicit device change; sign-in lifetime is unchanged.

Deploy the compatible API before distributing the app update. After recovered
registrations exist, **do not roll back to a server that ignores ownership**.
Leave the additive columns intact. Use a forward fix or an ownership-aware
rollback build that retains code-purpose checks and blocks unsafe registry
writes. Back up and test migrations using the instance's normal procedure.

## Verification

API tests cover wrong/expired codes, session/account binding, concurrent
confirmations, stale-device cleanup, idempotence, group epochs and peer reads.
Mobile tests cover explicit confirmation, cancellation, account changes, key
retention and logout ordering. The native protocol test uses an old device,
replacement and peer to verify the changed-identity handshake and fresh group
messages without wiping cached history.

Physical iOS and Android tests are still required before release: include
offline/retry, an older peer, group replies, deliberate logout on both devices
and unreadable historical messages. Never perform destructive recovery tests
on real users' accounts.
