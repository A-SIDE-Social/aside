# Contributing to A/SIDE

Thanks for your interest. A few up-front notes about scope so you
don't waste time on something we won't merge.

## Design principles (not up for debate)

These shape every decision and aren't open to PR-level discussion:

- **Closed network.** No public profiles, no name search, no
  discovery surface, no federation. Connections are mutual-only and
  invitation-driven.
- **End-to-end encrypted DMs always.** The crypto layer doesn't get
  weakened, replaced, or made optional. PRs that add server-side
  message inspection will be closed.
- **No ads, no AI training on user content, ever.** No analytics
  SDKs in the binary. No third-party trackers.
- **Chronological feed.** No algorithmic ranking, no recommendations,
  no "for you" surface.
- **Independent infrastructure.** No hard dependency on AWS / GCP /
  Azure-specific services. S3-compatible storage, plain Postgres,
  any container runtime.

PRs that conflict with these will be closed regardless of code
quality. If you want a different product, fork it — that's what
the AGPL is for.

## What we'll merge

- **Bug fixes.** Always welcome. Reproduction steps + a test help.
- **Performance improvements** with measurements showing the
  improvement.
- **Security improvements**, ideally coordinated through
  `security@a-side.social` first if they're sensitive (see
  `SECURITY.md`).
- **Accessibility improvements** to the mobile UI.
- **Translation work.** Open an issue first to coordinate.
- **Documentation improvements**, including README clarifications,
  setup guides, architecture docs.
- **Test coverage** for under-tested code paths.

## What we probably won't merge

- New features that aren't already on the roadmap. Open an issue
  first to discuss before writing code.
- Refactors with no functional benefit ("modernize this to use X").
- Adding analytics, ad SDKs, or anything that phones home.
- Federation / interop with other social protocols (ActivityPub,
  Nostr, AT Proto). Different product.
- New paid features held back from self-hosters (we keep the
  full feature set in the OSS repo; paid features are server-side
  enforced via subscription state, not feature-gated in the client).

## Development setup

See `README.md` "Running locally" section. Short version:

```sh
cp .env.example .env
docker compose up -d db
npm install
npm run migrate
npm run dev

# In another terminal:
cd mobile && flutter pub get && flutter run
```

## Style

### Server (TypeScript)

- TypeScript strict mode. `npm run lint` (= `tsc --noEmit`) must
  pass on every PR.
- Tests live in `tests/`. New routes need integration tests.
  See `tests/api.test.ts` for the existing patterns.
- Comments explain *why*, not *what*. The "why" is what's hard to
  recover from a `git blame`.

### Mobile (Flutter / Dart)

- `flutter analyze` must pass.
- New providers go in `mobile/lib/providers/`. Riverpod 3 with
  `Notifier` / `AsyncNotifier`, not the deprecated `StateNotifier`.
- New screens in `mobile/lib/features/<area>/`.
- `flutter test` must pass.

### Crypto / Rust

- Touching `mobile/rust/` requires a strong reason. The crypto layer
  is the most security-sensitive part of the codebase.
- Any change to the crypto layer should ideally be reviewed by
  someone with applied-cryptography experience.
- `cargo test` must pass.

## Pull request process

1. Open an issue first for anything that isn't a small bug fix.
2. Fork, branch from `main`, push your branch.
3. Open a PR. Include:
   - What changed and why.
   - How to test it.
   - Screenshots / video for UI changes.
4. CI must pass. Reviewer feedback gets addressed in additional
   commits (we squash on merge, so commit hygiene on the PR
   branch isn't critical).

## Disclosure

For security vulnerabilities, **please don't open a public issue.**
See `SECURITY.md` for the disclosure process. We aim to confirm
receipt within 48h.

## Code of conduct

See `CODE_OF_CONDUCT.md`. Be decent to each other. Reports go to
`conduct@a-side.social`.
