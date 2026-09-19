import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import performance as p

KEY = json.dumps(['aside_http_duration_seconds', 'GET', '/v1/feed/', 'ok'], separators=(',', ':'))

def sample(at, count=0, start=1, busy=False):
    return {'at': at, 'host': {'cpu': [at * 100, at * (5 if busy else 75)], 'memory_pct': 90 if busy else 45,
            'disk_pct': 30, 'available_mb': 450, 'swap_used_mb': 0},
            'api': {'start': start, 'gauges': {}, 'hist': {KEY: {'n': count, 'b': {'0.1': count, '+Inf': count}}}}}


class PerformanceTests(unittest.TestCase):
    def test_combined_histograms_are_not_averaged_percentiles(self):
        self.assertAlmostEqual(p.quantile({'0.1': 90, '1': 100, '+Inf': 100}, .95), .55)
        self.assertIsNone(p.quantile({'1': 0, '+Inf': 0}, .95))

    def test_resets_and_gaps_are_not_counted(self):
        records = [sample(1000, 10), sample(1060, 20), sample(1120, 2, 2), sample(1180, 5, 2), sample(1800, 100, 2)]
        report = p.summarize(records, 1800, 1)
        self.assertEqual(report['requests_excluding_health'], 13)
        self.assertEqual(report['observed_restarts'], 1)
        self.assertEqual(report['verdict'], 'insufficient_history')

    def test_quiet_window_does_not_claim_capacity(self):
        report = p.summarize([sample(1000 + i * 60) for i in range(61)], 4600, 1)
        self.assertEqual(report['api_coverage_pct'], 100)
        self.assertEqual(report['verdict'], 'low_traffic_no_capacity_conclusion')
        self.assertIsNone(report['successful_request_latency']['p95_ms'])

    def test_resize_requires_sustained_pressure_and_slowness(self):
        records = [sample(1000 + i * 60, i * 10, busy=True) for i in range(61)]
        for row in records:
            row['api']['hist'][KEY]['b'] = {'0.1': 0, '1': row['api']['hist'][KEY]['n'], '+Inf': row['api']['hist'][KEY]['n']}
        report = p.summarize(records, 4600, 1)
        self.assertEqual(report['verdict'], 'consider_resize_after_bottleneck_check')
        self.assertTrue(report['sustained_pressure_10min']['cpu'])
        records[-1]['at'] = 4540
        self.assertEqual(p.summarize(records[:-1], 5000, 1)['verdict'], 'insufficient_history')

    def test_missing_api_and_health_are_explicit(self):
        records = [sample(1000), sample(1060, 5), sample(1120, 10)]
        for row in records[:2]:
            row['api']['hist'] = {KEY.replace('/v1/feed/', '/health'): row['api']['hist'][KEY]}
        records[2]['api'] = None
        report = p.summarize(records, 1120, 1)
        self.assertEqual(report['requests_excluding_health'], 0)
        self.assertEqual(report['unavailable_api_samples'], 1)

    def test_collector_retains_only_own_recent_files(self):
        payload = {'started_at': 1, 'metrics': [{'name': 'unapproved_user_info', 'values': [{'value': 1, 'labels': {'email': 'secret'}}]}]}
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / '2000-01-01.jsonl.gz').write_bytes(b'old')
            (directory / 'leave-me.txt').write_text('keep')
            with patch.object(p, 'host_snapshot', return_value=sample(0)['host']), patch.object(p.subprocess, 'run') as run:
                run.return_value.stdout = json.dumps(payload).encode()
                p.collect(directory)
            records = list(p.read_samples(directory, 0))
            self.assertEqual(records[0]['api'], {'start': 1, 'hist': {}, 'gauges': {}})
            self.assertFalse((directory / '2000-01-01.jsonl.gz').exists())
            self.assertTrue((directory / 'leave-me.txt').exists())
            self.assertEqual(next(directory.glob('*.gz')).stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
