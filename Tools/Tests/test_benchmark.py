"""Fail closed when the framework omits or cannot populate a requested metric."""
from pathlib import Path
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import benchmark


class BenchmarkExportTests(unittest.TestCase):
    def rows(self, mode):
        metrics = ('Time (wall clock)', 'Time (total CPU)') if mode == 'timing' else (
            'Time (wall clock)', *benchmark.DIAGNOSTICS)
        names = (benchmark.SMOKE,) if mode == 'timing' else (benchmark.SMOKE, benchmark.PROBE)
        return [{'name': f'{name} - {metric}', 'value': 1, 'unit': '#'}
                for name in names for metric in metrics]

    def test_empty_missing_duplicate_nonfinite_and_extra_exports_fail(self):
        rows = self.rows('timing')
        bad = [[], rows[:1], rows + rows, rows + [{'name': 'unknown', 'value': 1, 'unit': '#'}],
               [{**rows[0], 'value': float('nan')}, rows[1]],
               [{**rows[0], 'value': 0}, rows[1]]]
        for data in bad:
            with self.subTest(data=data), self.assertRaises(ValueError):
                benchmark.validate_results(data, 'timing')
        self.assertEqual(benchmark.validate_results(rows, 'timing')['allocator'], 'disabled')

    def test_each_diagnostic_requires_positive_observed_probe(self):
        rows = self.rows('allocation')
        for metric in benchmark.DIAGNOSTICS:
            changed = [{**row, 'value': 0} if row['name'] == f'{benchmark.PROBE} - {metric}' else row
                       for row in rows]
            with self.subTest(metric=metric), self.assertRaises(ValueError):
                benchmark.validate_results(changed, 'allocation')

    def test_zero_workload_allocations_are_valid_with_positive_control(self):
        rows = self.rows('allocation')
        changed = [{**row, 'value': 0} if row['name'].startswith(benchmark.SMOKE) and 'Time' not in row['name']
                   else row for row in rows]
        self.assertEqual(benchmark.validate_results(changed, 'allocation')['metricCount'], 14)

    def test_framework_success_without_fresh_write_cannot_reuse_old_baseline(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(benchmark, 'PACKAGE', Path(directory)):
            previous = benchmark.baseline_path('timing-seed')
            previous.parent.mkdir(parents=True)
            previous.write_text('previous measurement')
            output = Path(directory) / 'output'
            output.mkdir()
            with self.assertRaisesRegex(ValueError, 'did not write'):
                with benchmark.capture_baseline(['plugin'], output, 'timing', lambda command: None):
                    self.fail('Missing fresh capture must not be accepted')
            self.assertEqual(previous.read_text(), 'previous measurement')
            self.assertEqual(list(previous.parent.parent.iterdir()), [previous.parent])

    def test_failed_atomic_promotion_preserves_previous_samples(self):
        raw = {'baselineName': 'fresh', 'results': [{'samples': [1, 2, 3]}], 'machine': {}}
        with tempfile.TemporaryDirectory() as directory, patch.object(benchmark, 'PACKAGE', Path(directory)):
            destination = benchmark.baseline_path('timing-seed')
            destination.parent.mkdir(parents=True)
            destination.write_text('previous measurement')
            with patch.object(benchmark.os, 'replace', side_effect=PermissionError('write denied')):
                with self.assertRaises(PermissionError):
                    benchmark.replace_baseline(raw, 'timing-seed')
            self.assertEqual(destination.read_text(), 'previous measurement')
            self.assertEqual(list(destination.parent.iterdir()), [destination])
            benchmark.replace_baseline(raw, 'timing-seed')
            stored = json.loads(destination.read_text())
            self.assertEqual(stored['results'], raw['results'])
            self.assertEqual(stored['baselineName'], 'timing-seed')
