# Account deletion policy

A/SIDE distinguishes reversible deactivation from permanent deletion.

- Deactivation sets `users.deleted_at` and can be restored by an operator.
- Permanent deletion removes the `users` row through `permanentlyDeleteUser`.
  The self-service API and the confirmed admin-dashboard action use this path.

## Relational policy

Migration `027_user_deletion_policy.sql` gives every direct foreign key to
`users` an explicit action. The integration suite queries PostgreSQL's catalog
and fails if a future relationship falls back to `NO ACTION`.

Private or dependent records use `ON DELETE CASCADE`, including invites owned
by the user, follows, posts and media metadata, lists, memberships, comments,
stories, direct conversations, conversation membership, messages authored by
the user, notifications addressed to the user, sessions, device/contact data,
preferences, subscriptions, and encryption keys.

Shared operational records use `ON DELETE SET NULL`, including an invite's
historical redeemer, a surviving group conversation's creator, notification
actors, admin-audit actors/targets, and broadcast initiators. Audit details for
the deleted target are cleared because they may contain an old email address.

Group conversations are the only domain-specific handoff. The deletion service
promotes the oldest remaining member in the same transaction. A group with no
remaining member is dissolved. Direct conversations are deleted when either
participant is deleted.

## Object storage

A `BEFORE DELETE` database trigger copies attributable object keys into
`media_deletion_queue` before relational cascades remove their source rows.
The API processes this outbox after commit and retries at startup and hourly.
Temporary object-storage failures therefore cannot partially restore the
database deletion or silently lose the cleanup work.

Encrypted DM attachment uploads are recorded in `dm_attachment_objects` from
migration 027 onward. Older encrypted attachment blobs were deliberately opaque
and were not associated with an uploader in the database, so they cannot be
retroactively attributed. Bucket lifecycle/retention policy remains the safety
net for those pre-migration objects.

## Operational use

Use the admin dashboard's **Permanently delete account** action for support
requests. It requires the operator to type `DELETE`, rejects self-deletion, and
uses the same transactional service as the API. Direct SQL deletion is
foreign-key safe and queues media, but it cannot perform group-admin handoff;
it should be reserved for recovery work.
