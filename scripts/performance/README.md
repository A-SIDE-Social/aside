# A/SIDE performance monitoring

A small first step for the single DigitalOcean droplet: private API histograms,
a local once-per-minute collector, and a deterministic report. No hosted APM,
user tracking, request logs, public metrics endpoint, or AI-powered polling.

## Enable

1. Deploy the API with `PERFORMANCE_METRICS=1` in its container environment.
   The default is off. Do **not** publish port 9464 or proxy it in Caddy.
2. Install Python 3 (standard library only). Copy `performance.py` to
   `/opt/aside-performance/performance.py`, owned by root, mode 0700.
3. Copy the service and timer here to `/etc/systemd/system/`, then run
   `systemctl daemon-reload` and `systemctl enable --now aside-performance.timer`.
   The default container name is `kin-api-1`; set `PERFORMANCE_CONTAINER` in a
   systemd service override if it changes.
4. Run `systemctl start aside-performance.service`, then
   `python3 /opt/aside-performance/performance.py report --hours 24`.
5. In DigitalOcean Monitoring, attach resource alerts to the API droplet:
   CPU above 80%, memory above 85%, disk above 80%, each for 10 minutes.
   Use the account owner's email. The DO metrics agent must be active.

The service writes root-only gzip snapshots under `/var/lib/aside-performance`.
It retains 14 UTC calendar dates (today plus 13 previous days). The timer does
not backfill missed samples. It records missing API observations explicitly.

## What the report means

- HTTP volume and latency exclude `/health`. Outcomes separate successful,
  client-error, server-error, and aborted requests. Latencies are histogram
  estimates from combined counter deltas, never averages of percentiles.
- HTTP labels contain the method and declared route template only. Unknown
  paths collapse to `unmatched`. No actual URLs, IDs, query strings, request
  bodies, emails, tokens, SQL statements, or message content are collected.
- `unmatched` also includes requests rejected by middleware before Express
  matches a route, including authentication and body parsing failures. It does
  not by itself establish that a URL was invalid or a request was a probe.
  `http_error_routes` separates client errors, server errors and aborts using
  existing history. New `http_failure_details` adds status and fixed reasons
  such as `auth_failure`, `malformed_body`, `route_not_found` and email delivery
  failures. A matched route returning 404 is `not_found`, not `route_not_found`.
  Error messages and provider response contents never become metric labels.
- Failure details require both the updated API and collector. The historical
  HTTP histogram format is unchanged. `http_failure_detail_coverage_pct` gives
  the portion of the requested window with the new counters; details are null
  when unavailable, rather than implying there were no failures. Older
  collectors ignore the new families and continue collecting existing metrics.
- `operation_stages` times OTP provider delivery and message sends. The message
  `prehandler` stage includes body transfer/parsing, authentication and rate
  limits; it is recorded only for requests that reach the send handler. The
  `handler` stage includes all handler work; `persist` and `fanout` are nested
  parts of that time, so do not add their percentiles together. Fanout includes
  socket emission and notification rows but excludes the existing asynchronous
  push-provider delivery. Stage labels are a fixed allowlist with no SQL,
  recipient IDs or message contents. An empty list may mean the updated
  instrumentation is absent or no matching operations occurred.
- Slow-route rows also show the number of successful requests over one second
  and 2.5 seconds. Check these counts alongside p95 when traffic is sparse.
- Query-helper latency includes acquiring the pool connection. Separately,
  pool-wait timing covers explicit `getClient()` calls used for transactions.
  Individual statements inside those transactions are not timed. The pool's
  queued/idle/total gauges are sampled once a minute and may miss short spikes.
- Process memory, event-loop lag, socket counts, and host CPU/memory/disk are
  included. This is server response time, not end-to-end mobile latency.
- Restarts and collection gaps are excluded from request counter deltas.
  Coverage and sample age are always reported. At least 80% of the requested
  window, 15 minutes of valid history, and fresh samples are needed for a
  verdict. Fewer than 100 requests cannot establish spare capacity.
- Sustained CPU >80% or RAM >85% for 10 minutes warrants investigation. Combined
  with successful-response p95 >500ms across at least 100 successful requests,
  the report suggests considering a resize **after** checking slow queries,
  pool waits, event-loop blocking and memory leaks. Thresholds are starting
  heuristics, not an SLO. Disk pressure usually calls for cleanup/storage work.
  Server errors can be application bugs; do not automatically resize.
- Percentiles at the 30-second upper finite bucket may represent longer waits.
  Requests spanning a restart or missed interval are not reconstructed.

## Run locally / verify

`npm test -- --runTestsByPath tests/performance.test.ts`

`python3 -m unittest discover -s scripts/performance -p 'test_*.py'`

The collector requires Linux `/proc` and Docker; the reporter and fixture tests
also run on macOS. Production runs Node 24; the maintained Prometheus client
supports Node 22/24/26+. No database migrations are required.

OTP delivery uses a ten-second Postmark SDK timeout with no automatic resend
on failure. A timeout can occur after the provider accepted the message; it
does not prove that no email was delivered. Production without a Postmark
token returns an explicit unavailable response instead of logging a code and
claiming success. Provider authentication, request rejection, inactive
recipient, rate limiting and availability failures are recorded as separate
bounded categories. They do not establish the cause of older unclassified
errors. See [Postmark's status and error-code reference](https://postmarkapp.com/developer/api/overview).

Mobile and admin code requests share a short transaction that serializes
issuance per email address. The database connection is released before email
delivery. A confirmed provider rejection expires only that request's code;
its row remains to enforce the 30-second cooldown. An uncertain transport or
server failure preserves the code until its usual expiry. An older request's
failure cannot invalidate a newer code. No schema migration is needed.

## Disable

Stop and disable `aside-performance.timer`; set `PERFORMANCE_METRICS=0` and
recreate the API container. This preserves history for inspection. Do not
change the database. The DO host agent/alerts can remain enabled independently.

References: [DigitalOcean agent](https://docs.digitalocean.com/products/monitoring/how-to/install-metrics-agent/),
[resource alerts](https://docs.digitalocean.com/products/monitoring/how-to/manage-alerts/),
[Prometheus Node client](https://github.com/prometheus/client_js).
