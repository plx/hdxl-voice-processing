"""Reject incomplete distributions, unavailable allocator hooks, and core transform allocations."""
import copy
import importlib.util
import math
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('level_benchmark', ROOT / 'Tools/Levels/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
MATRIX = [{'name':'case'}]


def capture(mode):
    names = [f'Level.{operation}.case' for operation in benchmark.OPERATIONS]
    if mode == 'allocation':
        names += [benchmark.CONTROL]
    metrics = ['wallClock','cpuTotal'] if mode == 'timing' else ['wallClock',*benchmark.DIAGNOSTICS]
    rows = []
    for name in names:
        values = []
        for metric in metrics:
            maximum = 1 if name == benchmark.CONTROL or name.startswith('Level.Prepare') or metric == 'wallClock' else 0
            values.append({'metric':{metric:{}}, 'scalingFactor':1,
                           'statistics':{'histogram':{'_totalCount':10,'maxValue':maximum,'counts':[10]}}})
        rows += [{'name':name,'target':'LevelBenchmarks'},values]
    return {'results':rows}


class LevelBenchmarkTests(unittest.TestCase):
    def test_allocation_capability_requires_each_positive_control(self):
        raw = capture('allocation')
        self.assertEqual(len(benchmark.validate_raw(raw,MATRIX,'allocation')),3)
        for metric in benchmark.DIAGNOSTICS:
            broken = copy.deepcopy(raw)
            for row in broken['results'][-1]:
                if metric in row['metric']:
                    row['statistics']['histogram']['maxValue'] = 0
            with self.assertRaisesRegex(ValueError,'Unavailable'):
                benchmark.validate_raw(broken,MATRIX,'allocation')

    def test_every_prepared_operation_requires_zero_maximum_heap_counts(self):
        for operation in benchmark.OPERATIONS[1:]:
            for metric in benchmark.ALLOCATIONS:
                raw = capture('allocation')
                for row in raw['results'][2*benchmark.OPERATIONS.index(operation)+1]:
                    if metric in row['metric']:
                        row['statistics']['histogram']['maxValue'] = 1
                with self.assertRaisesRegex(ValueError,'Steady-state'):
                    benchmark.validate_raw(raw,MATRIX,'allocation')

    def test_all_operations_are_required_in_both_modes(self):
        for mode in ('timing','allocation'):
            good = capture(mode)
            self.assertEqual(len(benchmark.validate_raw(good,MATRIX,mode)), 2 if mode=='timing' else 3)
            del good['results'][:2]
            with self.assertRaises(ValueError):
                benchmark.validate_raw(good,MATRIX,mode)

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

    def test_matrix_rejects_coverage_units_and_incorrect_availability(self):
        good = []
        for name, (precision, method, weighted, signal, geometry) in benchmark.expected_cases().items():
            configs, identities = [], []
            frames = warmup = workspace = input_bytes = 0
            for rate, ms in geometry:
                n, h = rate*ms//1000, rate//100
                configs.append({"sampleRate":rate,"windowLength":n,"hopLength":h,"inputPrecision":precision,
                    "arithmeticPrecision":"float64","accumulation":method,"partialWindowPolicy":"discard",
                    "weighting":{"kind":"bs1770Revision5","warmupSampleCount":rate//10} if weighted else {"kind":"none"},
                    "pcmReference":"unitPeak","channelPolicy":"monoAlreadySelected","averaging":"rectangularMeanSquare",
                    "energyUnit":"normalizedSquaredAmplitude","logLevelUnit":"decibelsFullScale",
                    "kWeighting":{"sampleRate":rate,"method":{"name":"bs1770-5-prewarped-tables","version":1}} if weighted else None})
                identities.append({"identifier":{"name":"digital-level-windows","version":1},"sha256":"0"*64})
                count=(rate-n)//h+1
                frames+=count;warmup+=10 if weighted else 0
                workspace+=n*(56 if weighted else 32);input_bytes+=rate*(4 if precision=="float32" else 8)
            eligible=frames-warmup if weighted else 0
            limited=eligible if precision=="float64" and signal=="denormal" else 0
            good.append({"name":name,"workload":{"name":name,"configurations":configs,"profileIdentities":identities,
                "signal":signal,"inputDurationSeconds":1,"inputChunkSamples":256,"instances":len(geometry)},
                "preparedBufferBytes":workspace,"preparedInputBytes":input_bytes,"frameCount":frames,"warmupWindowCount":warmup,
                "weightedAvailableWindowCount":eligible-limited,"weightedRangeLimitedWindowCount":limited,
                "subnormalInputWindowCount":frames if signal=="denormal" else 0,"checksum":0 if signal=="silence" else 1.0})
        self.assertEqual(len(benchmark.validate_matrix(good)),100)
        failures=[good[:-1],good+[good[0]]]
        for key,value in [("frameCount",0),("warmupWindowCount",10000),("weightedAvailableWindowCount",-1),
                          ("weightedRangeLimitedWindowCount",10),("preparedBufferBytes",0),("preparedInputBytes",0),
                          ("checksum",float("nan")),("checksum",0)]:
            bad=copy.deepcopy(good);bad[0][key]=value;failures.append(bad)
        for key,value in [("hopLength",1),("energyUnit","decibelsSPL"),("arithmeticPrecision","float32"),
                          ("weighting",{"kind":"bs1770Revision5","warmupSampleCount":0})]:
            bad=copy.deepcopy(good);bad[0]["workload"]["configurations"][0][key]=value;failures.append(bad)
        bad=copy.deepcopy(good);bad[-1]["workload"]["configurations"].pop();failures.append(bad)
        for bad in failures:
            with self.assertRaises(ValueError): benchmark.validate_matrix(bad)
