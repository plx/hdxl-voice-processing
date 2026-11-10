"""Synthetic measurement-receipt controls; these are not performance evidence."""
import copy
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('swipe_measurement_tested', ROOT / 'Tools/SWIPE/benchmark.py')
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)
MATRIX = [dict(algorithm=a, workload=dict(name='DeclaredCase', kind='Harmonic'))
          for a in ('SWIPEPrime', 'YINFFT')]


def raw_receipt(mode, matrix=MATRIX):
    names = [benchmark.benchmark_name(row, operation) for row in matrix
             for operation in benchmark.OPERATIONS]
    if mode == 'allocation':
        names.append(benchmark.CONTROL)
    rows = []
    for name in names:
        metrics = ('wallClock', 'cpuTotal') if mode == 'timing' else ('wallClock', *benchmark.DIAGNOSTICS)
        measurements = []
        for metric in metrics:
            maximum = 100 if metric in ('wallClock', 'cpuTotal') else 1
            if '.Run.' in name and metric in benchmark.ALLOCATIONS:
                maximum = 0
            measurements.append(dict(metric={metric: {}}, scalingFactor=1,
                                     statistics=dict(histogram=dict(_totalCount=10, maxValue=maximum, counts=[10]))))
        rows.extend([dict(name=name, target=benchmark.TARGET), measurements])
    return dict(results=rows)


class SWIPEBenchmarkTests(unittest.TestCase):
    def test_both_algorithms_both_operations_and_allocation_control_are_required(self):
        for mode, count in [('timing', 4), ('allocation', 5)]:
            raw = raw_receipt(mode)
            self.assertEqual(len(benchmark.validate_raw(raw, MATRIX, mode)), count)
            bad = copy.deepcopy(raw)
            del bad['results'][-2:]
            with self.assertRaises(ValueError):
                benchmark.validate_raw(bad, MATRIX, mode)
        raw = raw_receipt('allocation')
        mutations = {
            'wrong target': lambda r: r['results'][0].__setitem__('target', 'YINBenchmarks'),
            'duplicate row': lambda r: r['results'].__setitem__(2, copy.deepcopy(r['results'][0])),
            'extra metric': lambda r: r['results'][1].append(copy.deepcopy(r['results'][1][0])),
            'missing metric': lambda r: r['results'][1].pop(),
            'wrong scaling': lambda r: r['results'][1][0].__setitem__('scalingFactor', 1000),
            'boolean scaling': lambda r: r['results'][1][0].__setitem__('scalingFactor', True),
            'too few samples': lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('_totalCount', 9),
            'inconsistent counts': lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('counts', [9]),
            'boolean bucket': lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('counts', [True] * 10),
            'negative maximum': lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('maxValue', -1),
            'zero timing': lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('maxValue', 0),
            'silent control': lambda r: r['results'][-1][1]['statistics']['histogram'].__setitem__('maxValue', 0),
        }
        for label, mutate in mutations.items():
            with self.subTest(control=label):
                changed = copy.deepcopy(raw)
                mutate(changed)
                with self.assertRaises(ValueError):
                    benchmark.validate_raw(changed, MATRIX, 'allocation')

    def test_prepared_heap_allocations_fail_for_either_algorithm_but_owned_exports_are_explicit(self):
        for algorithm in ('SWIPEPrime', 'YINFFT'):
            for metric in benchmark.ALLOCATIONS:
                raw = raw_receipt('allocation')
                for index in range(0, len(raw['results']), 2):
                    if raw['results'][index]['name'] == f'SWIPEComparison.{algorithm}.Run.DeclaredCase':
                        for item in raw['results'][index + 1]:
                            if metric in item['metric']:
                                item['statistics']['histogram']['maxValue'] = 1
                with self.subTest(algorithm=algorithm, metric=metric):
                    with self.assertRaises(ValueError):
                        benchmark.validate_raw(raw, MATRIX, 'allocation')
                exports = copy.deepcopy(MATRIX)
                for row in exports:
                    row['workload']['kind'] = 'OwnedDiagnostics'
                benchmark.validate_raw(raw, exports, 'allocation')

    def test_export_metric_identity_units_and_coverage_fail_closed(self):
        for mode in ('timing', 'allocation'):
            names = benchmark.validate_raw(raw_receipt(mode), MATRIX, mode)
            metrics = ('Time (wall clock)', 'Time (total CPU)') if mode == 'timing' else (
                'Time (wall clock)', *benchmark.smoke.DIAGNOSTICS)
            rows = [dict(name=f'{name} - {metric}', value=1, unit='ns' if metric.startswith('Time (') else '#')
                    for name in names for metric in metrics]
            self.assertEqual(len(benchmark.validate_export(rows, names, mode)), len(names) * len(metrics))
            for bad in (rows[:-1], rows + [rows[0]], [dict(rows[0], unit='us'), *rows[1:]],
                        [dict(rows[0], value=True), *rows[1:]],
                        [dict(rows[0], value=float('nan')), *rows[1:]],
                        [dict(rows[0], value=-1), *rows[1:]]):
                with self.assertRaises(ValueError):
                    benchmark.validate_export(bad, names, mode)

    def test_native_stderr_is_retained_separately_from_json(self):
        command = [sys.executable, '-c', 'pass']
        completed = subprocess.CompletedProcess(command, 0, stdout='[{"value": 44}]', stderr='Verified input\n')
        log, records = io.StringIO(), []
        with patch.object(benchmark.subprocess, 'run', return_value=completed) as run:
            self.assertEqual(benchmark.capture_workloads(command, log, records), [dict(value=44)])
            self.assertEqual(run.call_args.kwargs['stdout'], subprocess.PIPE)
            self.assertEqual(run.call_args.kwargs['stderr'], subprocess.PIPE)
        self.assertIn('Verified input', log.getvalue())
        self.assertEqual(records[0]['exitCode'], 0)
        failed = subprocess.CompletedProcess(command, 17, stdout='[]', stderr='failure')
        with patch.object(benchmark.subprocess, 'run', return_value=failed):
            with self.assertRaises(RuntimeError):
                benchmark.capture_workloads(command, log, records)
        self.assertEqual(records[-1]['exitCode'], 17)
