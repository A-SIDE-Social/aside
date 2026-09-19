#!/usr/bin/env python3
"""Local aggregate performance history. Standard library only; never reads app logs."""
import argparse
import datetime as dt
import fcntl
import gzip
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time

HISTOGRAMS = {'aside_http_duration_seconds', 'aside_db_pool_wait_seconds', 'aside_db_query_seconds'}
GAUGES = {'process_resident_memory_bytes', 'nodejs_eventloop_lag_p99_seconds',
          'aside_db_pool_total', 'aside_db_pool_idle', 'aside_db_pool_waiting',
          'aside_websocket_connections', 'aside_metrics_recording_errors_total'}
FETCH = "fetch('http://127.0.0.1:9464/metrics.json',{signal:AbortSignal.timeout(5000)}).then(async r=>{if(!r.ok)throw Error('metrics unavailable');process.stdout.write(await r.text())}).catch(()=>process.exit(1))"


def finite(value):
    return isinstance(value, (int, float)) and math.isfinite(value)


def compact(payload):
    """Discard library metadata and all unapproved metric families/labels."""
    hist, gauges = {}, {}
    for family in payload['metrics']:
        name = family['name']
        if name in GAUGES:
            values = [v['value'] for v in family['values'] if not v.get('labels') and finite(v['value'])]
            if values:
                gauges[name] = values[0]
        if name not in HISTOGRAMS:
            continue
        for sample in family['values']:
            labels = sample.get('labels', {})
            allowed = {'outcome', 'le'} | ({'method', 'route'} if name == 'aside_http_duration_seconds' else set())
            if set(labels) - allowed or not finite(sample['value']):
                continue
            key = json.dumps([name, labels.get('method', ''), labels.get('route', ''), labels['outcome']], separators=(',', ':'))
            item = hist.setdefault(key, {'b': {}, 'n': 0})
            metric = sample['metricName']
            if metric.endswith('_bucket'):
                item['b'][str(labels['le'])] = sample['value']
            elif metric.endswith('_count'):
                item['n'] = sample['value']
    return {'start': payload['started_at'], 'hist': hist, 'gauges': gauges}


def host_snapshot():
    cpu = [int(v) for v in Path('/proc/stat').read_text().splitlines()[0].split()[1:9]]
    memory = {line.split(':')[0]: int(line.split()[1]) for line in Path('/proc/meminfo').read_text().splitlines()}
    disk = shutil.disk_usage('/')
    return {'cpu': [sum(cpu), cpu[3] + cpu[4]],
            'memory_pct': 100 * (1 - memory['MemAvailable'] / memory['MemTotal']),
            'available_mb': memory['MemAvailable'] / 1024,
            'swap_used_mb': (memory['SwapTotal'] - memory['SwapFree']) / 1024,
            'disk_pct': 100 * disk.used / disk.total}


def collect(directory):
    os.umask(0o077)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (directory / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        now = time.time()
        sample = {'at': now, 'host': host_snapshot(), 'api': None}
        try:
            result = subprocess.run(['docker', 'exec', os.getenv('PERFORMANCE_CONTAINER', 'kin-api-1'),
                                     'node', '-e', FETCH], capture_output=True, timeout=15, check=True)
            sample['api'] = compact(json.loads(result.stdout))
        except (subprocess.SubprocessError, ValueError, KeyError, TypeError):
            pass  # Preserve a gap explicitly, never write the response or stderr.
        day = dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime('%Y-%m-%d')
        with gzip.open(directory / (day + '.jsonl.gz'), 'at', encoding='utf-8') as output:
            output.write(json.dumps(sample, separators=(',', ':'), allow_nan=False) + '\n')
        cutoff = dt.datetime.fromtimestamp(now, dt.timezone.utc).date() - dt.timedelta(days=13)
        for path in directory.glob('????-??-??.jsonl.gz'):
            try:
                date = dt.date.fromisoformat(path.name[:10])
            except ValueError:
                continue
            if date < cutoff:
                path.unlink()
        print(json.dumps({'collected': True, 'api_available': sample['api'] is not None}))


def quantile(buckets, q):
    """Prometheus-style interpolation over combined cumulative bucket counts."""
    ordered = sorted((float(bound), count) for bound, count in buckets.items())
    if not ordered or ordered[-1][1] <= 0:
        return None
    rank, previous_bound, previous_count = q * ordered[-1][1], 0, 0
    for bound, count in ordered:
        if count >= rank:
            if math.isinf(bound):
                return previous_bound  # Above last finite bucket: lower bound only.
            return previous_bound + (bound - previous_bound) * (rank - previous_count) / (count - previous_count)
        previous_bound, previous_count = bound, count
    return None


def combine(target, incoming):
    for bound, value in incoming.items():
        target[bound] = target.get(bound, 0) + value


def series_summary(values):
    if not values:
        return None
    ordered = sorted(values)
    return {'median': round(statistics.median(values), 2),
            'p95': round(ordered[math.ceil(len(ordered) * .95) - 1], 2), 'max': round(max(values), 2)}


def summarize(samples, now, hours):
    cutoff = now - hours * 3600
    previous = None
    host_values = {k: [] for k in ('cpu_pct', 'memory_pct', 'disk_pct', 'available_mb', 'swap_used_mb')}
    peaks, totals, combined, routes = {}, {}, {}, {}
    covered, host_covered, points, restarts, unavailable = 0, 0, 0, 0, 0
    streak = {'cpu': 0, 'memory': 0}
    sustained = {'cpu': False, 'memory': False}
    latest = None
    for sample in samples:
        at = sample['at']
        if at < cutoff - 120 or at > now:
            continue
        if at < cutoff:
            previous = sample
            continue
        latest = at
        points += 1
        host, api = sample['host'], sample['api']
        unavailable += api is None
        for key in host_values:
            if key in host:
                host_values[key].append(host[key])
        if api:
            for key, value in api['gauges'].items():
                peaks[key] = max(peaks.get(key, value), value)
        elapsed = at - previous['at'] if previous else 0
        valid = 0 < elapsed <= 120 and previous['at'] >= cutoff
        if valid:
            host_covered += elapsed
            total = host['cpu'][0] - previous['host']['cpu'][0]
            idle = host['cpu'][1] - previous['host']['cpu'][1]
            cpu = 100 * (1 - idle / total) if total > 0 and 0 <= idle <= total else None
            if cpu is not None:
                host_values['cpu_pct'].append(cpu)
            for key, pressure in [('cpu', cpu is not None and cpu > 80), ('memory', host['memory_pct'] > 85)]:
                streak[key] = streak[key] + elapsed if pressure else 0
                sustained[key] |= streak[key] >= 600
        else:
            streak = dict.fromkeys(streak, 0)
        prev_api = previous['api'] if previous else None
        if valid and api and prev_api:
            if api['start'] != prev_api['start']:
                restarts += 1
            else:
                covered += elapsed
                for key, current in api['hist'].items():
                    old = prev_api['hist'].get(key, {'n': 0, 'b': {}})
                    delta = current['n'] - old['n']
                    buckets = {b: v - old['b'].get(b, 0) for b, v in current['b'].items()}
                    if delta < 0 or any(v < 0 for v in buckets.values()):
                        continue
                    name, method, route, outcome = json.loads(key)
                    if name == 'aside_http_duration_seconds' and route == '/health':
                        continue
                    totals[(name, outcome)] = totals.get((name, outcome), 0) + delta
                    combine(combined.setdefault((name, outcome), {}), buckets)
                    if name == 'aside_http_duration_seconds' and outcome == 'ok':
                        entry = routes.setdefault(method + ' ' + route, {'n': 0, 'b': {}})
                        entry['n'] += delta
                        combine(entry['b'], buckets)
        previous = sample
    http = 'aside_http_duration_seconds'
    requests = sum(v for (name, outcome), v in totals.items() if name == http)
    failures = totals.get((http, 'server_error'), 0) + totals.get((http, 'aborted'), 0)
    success = totals.get((http, 'ok'), 0)
    def latency(name):
        buckets = combined.get((name, 'ok'), {})
        return {label: (round(value * 1000, 2) if value is not None else None)
                for label, value in ((f'p{int(q*100)}_ms', quantile(buckets, q)) for q in (.5, .95, .99))}
    latency_http = latency(http)
    age = now - latest if latest is not None else None
    coverage = covered / (hours * 3600)
    enough = covered >= 900 and coverage >= .8 and age is not None and age < 180
    pressure = any(sustained.values())
    slow = success >= 100 and (latency_http['p95_ms'] or 0) > 500
    verdict = 'insufficient_history'
    if enough:
        verdict = 'healthy_observed_window'
        if requests < 100:
            verdict = 'low_traffic_no_capacity_conclusion'
        if pressure or failures or slow or unavailable or peaks.get('aside_metrics_recording_errors_total', 0) or (host_values['disk_pct'] and max(host_values['disk_pct']) > 80):
            verdict = 'investigate'
        if pressure and slow:
            verdict = 'consider_resize_after_bottleneck_check'
    top = [{'route': route, 'requests': value['n'], 'p95_ms': round(quantile(value['b'], .95) * 1000, 2)}
           for route, value in routes.items() if value['n'] >= 10]
    top.sort(key=lambda row: row['p95_ms'], reverse=True)
    return {'verdict': verdict, 'window_hours': hours, 'samples': points,
            'api_coverage_pct': round(coverage * 100, 1), 'host_coverage_pct': round(host_covered / (hours * 36), 1),
            'latest_sample_age_seconds': round(age) if age is not None else None,
            'unavailable_api_samples': unavailable, 'observed_restarts': restarts,
            'requests_excluding_health': requests, 'server_errors_or_aborts': failures,
            'client_errors': totals.get((http, 'client_error'), 0), 'successful_request_latency': latency_http,
            'query_helper_latency_including_pool': latency('aside_db_query_seconds'),
            'query_helper_errors': totals.get(('aside_db_query_seconds', 'error'), 0),
            'explicit_connection_acquisition_latency': latency('aside_db_pool_wait_seconds'),
            'host': {key: series_summary(values) for key, values in host_values.items()},
            'sustained_pressure_10min': sustained, 'gauge_peaks': peaks, 'slowest_routes_min_10_requests': top[:5],
            'notes': 'Latencies are histogram estimates; values at 30000ms may exceed the final finite bucket. Gaps/restarts are excluded. These are observed loads, not a capacity test.'}


def read_samples(directory, cutoff):
    earliest = dt.datetime.fromtimestamp(cutoff - 120, dt.timezone.utc).strftime('%Y-%m-%d')
    for path in sorted(directory.glob('????-??-??.jsonl.gz')):
        if path.name[:10] < earliest:
            continue
        with gzip.open(path, 'rt', encoding='utf-8') as source:
            for line in source:
                yield json.loads(line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['collect', 'report'])
    parser.add_argument('--directory', type=Path, default=Path('/var/lib/aside-performance'))
    parser.add_argument('--hours', type=int, choices=range(1, 337), default=24, metavar='1..336')
    args = parser.parse_args()
    if args.command == 'collect':
        collect(args.directory)
    else:
        now = time.time()
        lock_path = args.directory / '.lock'
        if lock_path.exists():
            # A concurrent gzip append must finish before the report reads it.
            with lock_path.open('rb') as lock:
                fcntl.flock(lock, fcntl.LOCK_SH)
                report = summarize(read_samples(args.directory, now - args.hours * 3600), now, args.hours)
        else:
            report = summarize([], now, args.hours)
        print(json.dumps(report, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
