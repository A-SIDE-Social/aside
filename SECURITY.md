# Security policy

A/SIDE's whole pitch is auditable trust claims. We take security
disclosures seriously and process them quickly.

## Reporting a vulnerability

**Please don't open a public GitHub issue.**

Email `security@a-side.social`. If you need to send highly sensitive
details, say so in the first email and we will coordinate an encrypted
channel.

Include:

- A description of the vulnerability and its impact.
- Steps to reproduce, ideally with a working proof-of-concept.
- Any relevant version / commit / build info.
- Whether you've shared this with anyone else.

## What we'll do

- **Within 48 hours**: confirm receipt and provide an initial
  assessment.
- **Within 14 days for critical / 30 days for medium**: ship a fix,
  or provide a clear explanation of the timeline if longer is
  required.
- **After the fix is deployed**: coordinate public disclosure with
  you. We default to crediting researchers in the release notes
  unless you prefer to remain anonymous.

## Scope

**In scope:**

- Authentication and authorization bugs (OTP flow, JWT handling,
  session management).
- Authorization bypass on any `/v1/*` endpoint.
- E2EE implementation flaws (Signal Protocol integration, Kyber
  prekey handling, key rotation, session resumption).
- Push notification metadata leakage (anything plaintext in FCM
  payloads that shouldn't be).
- Server-side data retention beyond what the privacy policy
  describes.
- Privilege escalation in the admin surface.
- SQL injection, XSS, CSRF.
- Local storage flaws on mobile (key material at rest).

**Out of scope:**

- Self-hosted deployments by third parties — we can only speak for
  the hosted A/SIDE at <https://a-side.social>.
- Rate-limit bypass that doesn't lead to a meaningful impact (e.g.
  enumeration of public-by-design data).
- Vulnerabilities in dependencies that we don't trigger.
- Social engineering, phishing of users or staff.
- Denial-of-service via volumetric traffic.
- Theoretical attacks without a demonstrated impact.

## Bug bounty

We're a small team and don't run a formal bounty program yet.
Token rewards are available for impactful findings:

- **Critical** (account takeover, full E2EE compromise, mass PII
  exposure): up to **$2,000**.
- **High** (single-account compromise, unauthorized DM read,
  privilege escalation): up to **$500**.
- **Medium** (information disclosure, IDOR with limited impact):
  up to **$200**.
- **Low / informational**: a thank-you and credit in the release
  notes.

Amounts are at our discretion based on severity, novelty, and
quality of the report.

## Upstream audits

A/SIDE's E2EE layer is built on top of well-audited primitives:

- **[`libsignal`](https://github.com/signalapp/libsignal)** — the
  Signal Protocol implementation, audited multiple times by NCC
  Group and others. See Signal's published audit reports.
- **MLKEM (Kyber)** — NIST-standardized post-quantum key
  encapsulation (FIPS 203), with extensive academic and industry
  scrutiny.

A formal third-party audit of the A/SIDE-specific integration
(application of `libsignal` + Kyber + the server-side envelope
handling) is on our roadmap but not yet completed. Findings from
such an audit will be published once available.

## Hall of fame

We'll list researchers who've responsibly disclosed valid findings
here, with their permission.

_(empty for now — be the first)_
