"""Require complete large-transform distributions and usable memory/allocation evidence."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('large_fourier_benchmark', ROOT / 'Tools/Fourier/large_benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
MATRIX = [{'name': 'case'}]


def capture(mode):
    names = [f'LargeFourier.{operation}.case' for operation in benchmark.OPERATIONS]
    if mode == 'allocation':
        names.append(benchmark.CONTROL)
    metrics = ['wallClock', 'cpuTotal', 'peakMemoryResident'] if mode == 'timing' else ['wallClock', 'peakMemoryResident', *benchmark.DIAGNOSTICS]
    rows = []
    for name in names:
        values = []
        for metric in metrics:
            maximum = 1 if name == benchmark.CONTROL or name.startswith('LargeFourier.Prepare') or metric in ('wallClock', 'peakMemoryResident') else 0
            values.append({'metric': {metric: {}}, 'scalingFactor': 1,
                           'statistics': {'histogram': {'_totalCount': 10, 'maxValue': maximum, 'counts': [10]}}})
        rows += [{'name': name, 'target': 'LargeFourierBenchmarks'}, values]
    return {'results': rows}


class LargeFourierBenchmarkTests(unittest.TestCase):
    def test_memory_observations_required_for_every_operation(self):
        for mode in ('timing', 'allocation'):
            raw = capture(mode)
            self.assertEqual(len(benchmark.validate_raw(raw, MATRIX, mode)), 5 if mode == 'timing' else 6)
            for index in range(5):
                broken = copy.deepcopy(raw)
                for row in broken['results'][2 * index + 1]:
                    if 'peakMemoryResident' in row['metric']:
                        row['statistics']['histogram']['maxValue'] = 0
                with self.assertRaisesRegex(ValueError, 'Resident memory'):
                    benchmark.validate_raw(broken, MATRIX, mode)

    def test_allocation_hooks_require_positive_controls_and_zero_prepared_heap(self):
        raw = capture('allocation')
        for metric in benchmark.DIAGNOSTICS:
            broken = copy.deepcopy(raw)
            for row in broken['results'][-1]:
                if metric in row['metric']:
                    row['statistics']['histogram']['maxValue'] = 0
            with self.assertRaisesRegex(ValueError, 'Unavailable'):
                benchmark.validate_raw(broken, MATRIX, 'allocation')
        for index in range(1, 5):
            for metric in benchmark.ALLOCATIONS:
                broken = copy.deepcopy(raw)
                for row in broken['results'][2 * index + 1]:
                    if metric in row['metric']:
                        row['statistics']['histogram']['maxValue'] = 1
                with self.assertRaisesRegex(ValueError, 'Steady-state'):
                    benchmark.validate_raw(broken, MATRIX, 'allocation')

    def test_missing_duplicate_unscaled_and_insufficient_distributions_fail(self):
        raw = capture('timing')
        failures = []
        broken = copy.deepcopy(raw); del broken['results'][-2:]; failures.append(broken)
        broken = copy.deepcopy(raw); broken['results'][2] = broken['results'][0]; failures.append(broken)
        broken = copy.deepcopy(raw); broken['results'][1].pop(); failures.append(broken)
        broken = copy.deepcopy(raw); broken['results'][1][0]['scalingFactor'] = 100; failures.append(broken)
        broken = copy.deepcopy(raw); broken['results'][1][0]['statistics']['histogram']['_totalCount'] = 9; failures.append(broken)
        broken = copy.deepcopy(raw); broken['results'][1][0]['statistics']['histogram']['counts'] = [9]; failures.append(broken)
        for broken in failures:
            with self.assertRaises(ValueError):
                benchmark.validate_raw(broken, MATRIX, 'timing')

    def test_export_requires_exact_memory_units_and_complete_metrics(self):
        rows = [{'name': f'case - {metric}', 'value': 3, 'unit': unit}
                for metric, unit in [('Time (wall clock)', 'ns'), ('Time (total CPU)', 'ns'), ('Memory (resident peak)', '#')]]
        self.assertEqual(len(benchmark.validate_export(rows, ['case'], 'timing')), 3)
        for broken in [rows[:2], rows + rows, [*rows[:2], {**rows[2], 'unit': 'MB'}],
                       [*rows[:2], {**rows[2], 'value': float('nan')}], [*rows[:2], {**rows[2], 'value': True}]]:
            with self.assertRaises(ValueError):
                benchmark.validate_export(broken, ['case'], 'timing')
