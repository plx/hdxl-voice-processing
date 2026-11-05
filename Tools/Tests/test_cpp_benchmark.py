"""Guard CPP evidence coverage and allocation exemptions."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('cpp_benchmark', ROOT / 'Tools/CPP/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
KINDS = ('FitSearch', 'OwnedDiagnostics', 'InputConversionChecksum', 'IntervalCPP', 'PreviewCPP')
MATRIX = [{'name': k, 'workload': {'kind': k}} for k in KINDS]


def capture(mode):
    names = [f'CPP.{op}.{k}' for k in KINDS for op in benchmark.OPERATIONS]
    if mode == 'allocation':
        names += [benchmark.CONTROL]
    metrics = ['wallClock', 'cpuTotal'] if mode == 'timing' else ['wallClock', *benchmark.DIAGNOSTICS]
    rows = []
    for name in names:
        values = []
        allocating = name == benchmark.CONTROL or '.Prepare.' in name or name.endswith(('OwnedDiagnostics',))
        for metric in metrics:
            maximum = 1 if allocating or metric in ('wallClock', 'cpuTotal') else 0
            values.append({'metric': {metric: {}}, 'scalingFactor': 1,
                           'statistics': {'histogram': {'_totalCount': 10, 'maxValue': maximum, 'counts': [10]}}})
        rows += [{'name': name, 'target': 'CPPBenchmarks'}, values]
    return {'results': rows}


class CPPBenchmarkTests(unittest.TestCase):
    def test_positive_control_requires_every_counter(self):
        good = capture('allocation')
        self.assertEqual(len(benchmark.validate_raw(good, MATRIX, 'allocation')), 11)
        for metric in benchmark.DIAGNOSTICS:
            bad = copy.deepcopy(good)
            for value in bad['results'][-1]:
                if metric in value['metric']:
                    value['statistics']['histogram']['maxValue'] = 0
            with self.assertRaisesRegex(ValueError, 'Unavailable'):
                benchmark.validate_raw(bad, MATRIX, 'allocation')

    def test_only_explicit_owned_exports_may_allocate(self):
        for i, kind in enumerate(KINDS):
            if kind in ('OwnedDiagnostics',):
                continue  # Positive owned allocations already accepted by the unmodified capture.
            for metric in benchmark.ALLOCATIONS:
                bad = capture('allocation')
                for value in bad['results'][4 * i + 3]:
                    if metric in value['metric']:
                        value['statistics']['histogram']['maxValue'] = 1
                with self.assertRaisesRegex(ValueError, 'Steady-state'):
                    benchmark.validate_raw(bad, MATRIX, 'allocation')

    def test_distribution_coverage_and_units(self):
        for mode in ('timing', 'allocation'):
            good = capture(mode)
            benchmark.validate_raw(good, MATRIX, mode)
            changes = [lambda r: r['results'].pop(),
                       lambda r: r['results'].__setitem__(2, r['results'][0]),
                       lambda r: r['results'][1].pop(),
                       lambda r: r['results'][1][0].__setitem__('scalingFactor', 100),
                       lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('_totalCount', 9),
                       lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('counts', [9])]
            for change in changes:
                bad = copy.deepcopy(good); change(bad)
                with self.assertRaises(ValueError):
                    benchmark.validate_raw(bad, MATRIX, mode)
        rows = [{'name': f'case - {m}', 'value': 3, 'unit': 'ns'} for m in ('Time (wall clock)', 'Time (total CPU)')]
        benchmark.validate_export(rows, ['case'], 'timing')
        for bad in (rows[:1], rows + rows, [{**rows[0], 'unit': 'ms'}, rows[1]],
                    [{**rows[0], 'value': float('nan')}, rows[1]]):
            with self.assertRaises(ValueError): benchmark.validate_export(bad, ['case'], 'timing')

    def test_shards_partition_the_required_workload(self):
        all_cases = benchmark.expected_cases()
        self.assertEqual(len(all_cases), 77)
        groups = [set(benchmark.expected_cases(shard)) for shard in benchmark.SHARDS]
        self.assertEqual([len(g) for g in groups], [53, 6, 6, 6, 6])
        self.assertEqual(set.union(*groups), set(all_cases))
        self.assertEqual(sum(map(len, groups)), len(all_cases))
        self.assertEqual(sum(row[3] / row[2] == 60 for row in all_cases.values()
                             if row[0] in ('IntervalCPP', 'PreviewCPP')), 12)
        self.assertEqual({row[6] for row in all_cases.values()}, set(benchmark.METHODS))
        self.assertEqual({row[3] for row in all_cases.values() if row[0] == 'FitSearch'}, {257, 513, 1025})
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            benchmark.expected_cases('float16-96000')

    def test_rejects_corrupt_geometry_recipe_work_and_frame_coverage(self):
        # Captured recipe/checksum metadata, not numerical output goldens. Restrict
        # membership to these examples while retaining all production field checks.
        examples = json.loads(r'''[{"availableFrameCount":1,"checksum":24.862822006751816,"cppBufferBytes":24600,"emittedFrameCount":1,"exportedScalarCount":0,"fitPointCount":512,"inputDurationSeconds":0,"inputSHA256":"def72686ac8ad80fb8c2ca49c9111fb8519880c4812670947e4576b1962cf816","name":"FitSearch.513bins.Dense.praat7002Robust.parabolic","preparedBufferBytes":24600,"preparedInputBytes":4104,"slopeEvaluationCount":261121,"unavailableFrameCount":0,"workload":{"configuration":{"conditioning":{"declaredInputBandwidthHz":5000,"gainPolicy":"none","method":{"interpolationDepth":50,"kind":"praat7WholeInterval"},"preEmphasisFromHz":null,"precision":"float64","ratio":{"denominator":1,"numerator":1},"requiredInputBandwidthHz":5000,"schemaVersion":1,"sourceSampleRate":10000,"targetSampleRate":10000},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"hopSeconds":0.002,"inputPrecision":"float64","preEmphasisFromHz":50,"previewHopLength":null,"schemaVersion":1},"densePeaks":true,"inputChunkSamples":256,"inputSampleCount":513,"kind":"FitSearch","name":"FitSearch.513bins.Dense.praat7002Robust.parabolic","profile":{"cepstrogram":null,"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"schemaVersion":1,"settings":{"fitEndSeconds":0,"fitMethod":"praat7002Robust","fitStartSeconds":0.001,"interpolation":"parabolic","pitchCeilingHz":330,"pitchFloorHz":60,"schemaVersion":1}},"profileIdentity":{"identifier":{"name":"praat-7.0.02-straight-cpp","version":1},"sha256":"8a55936c5fbd9f4467704f2c3887a8b96dddfba076f016a6796b21753dc54c1d"}}},{"availableFrameCount":451,"checksum":10063.569690165132,"cppBufferBytes":24600,"emittedFrameCount":451,"exportedScalarCount":0,"fitPointCount":512,"inputDurationSeconds":1,"inputSHA256":"03ff3875b0cba4c906a3dbb60f81cb32922c9aee316364390efef3d906634efc","name":"IntervalCPP.float64.16000Hz.16000samples.2ms","preparedBufferBytes":1367592,"preparedInputBytes":128000,"slopeEvaluationCount":261121,"unavailableFrameCount":0,"workload":{"configuration":{"conditioning":{"declaredInputBandwidthHz":8000,"gainPolicy":"none","method":{"interpolationDepth":50,"kind":"praat7WholeInterval"},"preEmphasisFromHz":null,"precision":"float64","ratio":{"denominator":8,"numerator":5},"requiredInputBandwidthHz":5000,"schemaVersion":1,"sourceSampleRate":16000,"targetSampleRate":10000},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"hopSeconds":0.002,"inputPrecision":"float64","preEmphasisFromHz":50,"previewHopLength":null,"schemaVersion":1},"densePeaks":false,"inputChunkSamples":256,"inputSampleCount":16000,"kind":"IntervalCPP","name":"IntervalCPP.float64.16000Hz.16000samples.2ms","profile":{"cepstrogram":{"conditioning":{"declaredInputBandwidthHz":8000,"gainPolicy":"none","method":{"interpolationDepth":50,"kind":"praat7WholeInterval"},"preEmphasisFromHz":null,"precision":"float64","ratio":{"denominator":8,"numerator":5},"requiredInputBandwidthHz":5000,"schemaVersion":1,"sourceSampleRate":16000,"targetSampleRate":10000},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"hopSeconds":0.002,"inputPrecision":"float64","preEmphasisFromHz":50,"previewHopLength":null,"schemaVersion":1},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"schemaVersion":1,"settings":{"fitEndSeconds":0,"fitMethod":"praat7002Robust","fitStartSeconds":0.001,"interpolation":"parabolic","pitchCeilingHz":330,"pitchFloorHz":60,"schemaVersion":1}},"profileIdentity":{"identifier":{"name":"praat-7.0.02-straight-cpp","version":1},"sha256":"5f01ff3268545fea73e64b21678e06db56c4bb91451696505e54d66d4fb07381"}}}]''')
        expected = {r['name']: benchmark.expected_cases()[r['name']] for r in examples}
        with patch.object(benchmark, 'expected_cases', return_value=expected):
            benchmark.validate_matrix(examples)
            changes = [
                lambda r: r.pop(),
                lambda r: r.append(r[0]),
                lambda r: r[0].__setitem__('fitPointCount', 491),
                lambda r: r[0].__setitem__('slopeEvaluationCount', 512 * 511),
                lambda r: r[0].__setitem__('preparedBufferBytes', 0),
                lambda r: r[0].__setitem__('cppBufferBytes', True),
                lambda r: r[0].__setitem__('inputSHA256', 'x' * 64),
                lambda r: r[0].__setitem__('inputDurationSeconds', 0.1),
                lambda r: r[0].__setitem__('checksum', float('nan')),
                lambda r: r[0]['workload']['profile']['settings'].__setitem__('fitMethod', 'siegelRepeatedMedian'),
                lambda r: r[0]['workload']['profileIdentity'].__setitem__('sha256', ''),
                lambda r: r[1].__setitem__('availableFrameCount', 0),
                lambda r: r[1].__setitem__('unavailableFrameCount', 1),
                lambda r: r[1].__setitem__('exportedScalarCount', 1),
                lambda r: r[1]['workload']['configuration'].__setitem__('inputPrecision', 'float32'),
                lambda r: r[1]['workload']['profile'].__setitem__('cepstrogram', None),
            ]
            for change in changes:
                bad = copy.deepcopy(examples)
                change(bad)
                with self.assertRaises(ValueError):
                    benchmark.validate_matrix(bad)
