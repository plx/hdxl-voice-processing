"""Reject incomplete distributions, unavailable allocator hooks, and core transform allocations."""
import copy
import importlib.util
import math
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('conditioning_benchmark', ROOT / 'Tools/Conditioning/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
MATRIX = [{'name':'case'}]


def capture(mode):
    names = [f'Conditioning.{operation}.case' for operation in benchmark.OPERATIONS]
    if mode == 'allocation':
        names += [benchmark.CONTROL]
    metrics = ['wallClock','cpuTotal'] if mode == 'timing' else ['wallClock',*benchmark.DIAGNOSTICS]
    rows = []
    for name in names:
        values = []
        for metric in metrics:
            maximum = 1 if name == benchmark.CONTROL or name.startswith('Conditioning.Prepare') or metric == 'wallClock' else 0
            values.append({'metric':{metric:{}}, 'scalingFactor':1,
                           'statistics':{'histogram':{'_totalCount':10,'maxValue':maximum,'counts':[10]}}})
        rows += [{'name':name,'target':'ConditioningBenchmarks'},values]
    return {'results':rows}


class ConditioningBenchmarkTests(unittest.TestCase):
    def test_allocation_capability_requires_each_positive_control(self):
        raw = capture('allocation')
        self.assertEqual(len(benchmark.validate_raw(raw,MATRIX,'allocation')),4)
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
            self.assertEqual(len(benchmark.validate_raw(good,MATRIX,mode)), 3 if mode=='timing' else 4)
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

    def test_matrix_rejects_missing_geometry_delay_and_partition_mismatches(self):
        good = []
        for source in (16000,44100,48000):
            for target in (10000,11000,16000):
                for precision in ('float32','float64'):
                    for profile in ('Praat7','Preview'):
                        lengths = [(1,c) for c in (64,256,1024)] + ([(60,1024)] if target==10000 else [])
                        for duration, chunk in lengths:
                            name = f'{profile}.{precision}.{source}-{target}Hz.{duration}s.C{chunk}'
                            method = {'kind':'praat7WholeInterval','interpolationDepth':50} if profile=='Praat7' else {'kind':'streamingPreview','lobes':32,'cutoffFraction':.9}
                            count = duration*target
                            delay = duration/2 if profile=='Praat7' else (math.ceil(32/min(1,target/source))+.5)/source
                            good.append({'name':name,'workload':{'name':name,'configuration':{'sourceSampleRate':source,
                                'targetSampleRate':target,'precision':precision,'method':method,'preEmphasisFromHz':50,'gainPolicy':'none'},
                                'inputDurationSeconds':duration,'inputChunkSamples':chunk,'frameSamples':1024,'hopSamples':256,
                                'fftLength':1024,'outputBlockCapacity':256,'intervalsPerIteration':1},
                                'outputSampleCount':count,'pipelineFrameCount':(count-1024)//256+1,
                                'preparedInputBytes':duration*source*(4 if precision=='float32' else 8),
                                'conditionerScalarWorkspaceBytes':100,'pipelineScalarWorkspaceBytes':200,
                                'filterDelaySeconds':delay,'outputEnergy':1.,'pipelineSpectralEnergy':2.})
        self.assertEqual(len(benchmark.validate_matrix(good)),120)
        failures = [good[:-1],good+[good[0]]]
        for key, value in [('outputSampleCount',0),('pipelineFrameCount',0),('filterDelaySeconds',0),
                           ('outputEnergy',float('nan')),('preparedInputBytes',0),('pipelineScalarWorkspaceBytes',0),
                           ('outputEnergy',2.)]:
            bad=copy.deepcopy(good);bad[0][key]=value;failures.append(bad)
        bad=copy.deepcopy(good);bad[0]['workload']['hopSamples']=512;failures.append(bad)
        for bad in failures:
            with self.assertRaises(ValueError): benchmark.validate_matrix(bad)
