"""Reject incomplete distributions, unavailable allocator hooks, and core transform allocations."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('fourier_benchmark', ROOT / 'Tools/Fourier/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
MATRIX = [{'name':'case','configuration':{'length':256}}]


def capture(mode):
    names = [f'Fourier.{operation}.case' for operation in benchmark.OPERATIONS]
    if mode == 'timing':
        names += [f'Fourier.{order}{operation}.case' for order in ('Sequential4','Concurrent4') for operation in ('Spectrum','Cepstrum')]
    else:
        names += [benchmark.CONTROL]
    metrics = ['wallClock','cpuTotal'] if mode == 'timing' else ['wallClock',*benchmark.DIAGNOSTICS]
    rows = []
    for name in names:
        values = []
        for metric in metrics:
            maximum = 1 if name == benchmark.CONTROL or name.startswith('Fourier.Prepare') or metric == 'wallClock' else 0
            values.append({'metric':{metric:{}}, 'scalingFactor':1,
                           'statistics':{'histogram':{'_totalCount':10,'maxValue':maximum,'counts':[10]}}})
        rows += [{'name':name,'target':'FourierBenchmarks'},values]
    return {'results':rows}


class FourierBenchmarkTests(unittest.TestCase):
    def test_allocation_capability_requires_each_positive_control(self):
        raw = capture('allocation')
        self.assertEqual(len(benchmark.validate_raw(raw,MATRIX,'allocation')),9)
        for metric in benchmark.DIAGNOSTICS:
            broken = copy.deepcopy(raw)
            for row in broken['results'][-1]:
                if metric in row['metric']:
                    row['statistics']['histogram']['maxValue'] = 0
            with self.assertRaisesRegex(ValueError,'Unavailable'):
                benchmark.validate_raw(broken,MATRIX,'allocation')

    def test_every_prepared_operation_requires_zero_maximum_heap_counts(self):
        for operation in benchmark.OPERATIONS[2:]:
            for metric in benchmark.ALLOCATIONS:
                raw = capture('allocation')
                for row in raw['results'][2*benchmark.OPERATIONS.index(operation)+1]:
                    if metric in row['metric']:
                        row['statistics']['histogram']['maxValue'] = 1
                with self.assertRaisesRegex(ValueError,'Steady-state'):
                    benchmark.validate_raw(raw,MATRIX,'allocation')

    def test_four_worker_comparisons_are_required_only_in_timing(self):
        good = capture('timing')
        self.assertEqual(len(benchmark.validate_raw(good,MATRIX,'timing')),12)
        bad = copy.deepcopy(good)
        del bad['results'][-2:]
        with self.assertRaises(ValueError):
            benchmark.validate_raw(bad,MATRIX,'timing')
        with self.assertRaises(ValueError):
            benchmark.validate_raw(good,MATRIX,'allocation')

    def test_missing_duplicate_or_too_few_samples_and_units_fail(self):
        good = capture('timing')
        failures = []
        bad = copy.deepcopy(good); bad['results'][2] = bad['results'][0]; failures.append(bad)
        bad = copy.deepcopy(good); bad['results'][1].pop(); failures.append(bad)
        bad = copy.deepcopy(good); bad['results'][1][0]['scalingFactor'] = 100; failures.append(bad)
        bad = copy.deepcopy(good); bad['results'][1][0]['statistics']['histogram']['_totalCount'] = 9; failures.append(bad)
        bad = copy.deepcopy(good); bad['results'][1][0]['statistics']['histogram']['counts'] = [9]; failures.append(bad)
        for raw in failures:
            with self.assertRaises(ValueError):
                benchmark.validate_raw(raw,MATRIX,'timing')
        rows = [{'name':f'case - {metric}','value':3,'unit':'ns'} for metric in ('Time (wall clock)','Time (total CPU)')]
        self.assertEqual(len(benchmark.validate_export(rows,['case'],'timing')),2)
        for bad in [rows[:1],rows+rows,[{**rows[0],'unit':'ms'},rows[1]], [{**rows[0],'value':float('nan')},rows[1]]]:
            with self.assertRaises(ValueError):
                benchmark.validate_export(bad,['case'],'timing')
