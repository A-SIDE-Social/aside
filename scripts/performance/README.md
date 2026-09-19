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

## Disable

Stop and disable `aside-performance.timer`; set `PERFORMANCE_METRICS=0` and
recreate the API container. This preserves history for inspection. Do not
change the database. The DO host agent/alerts can remain enabled independently.

References: [DigitalOcean agent](https://docs.digitalocean.com/products/monitoring/how-to/install-metrics-agent/),
[resource alerts](https://docs.digitalocean.com/products/monitoring/how-to/manage-alerts/),
[Prometheus Node client](https://github.com/prometheus/client_js).
