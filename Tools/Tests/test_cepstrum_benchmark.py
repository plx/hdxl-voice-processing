"""Guard cepstral evidence coverage, arithmetic identity, and allocation exemptions."""
import copy
import importlib.util
import math
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('cepstrum_benchmark', ROOT / 'Tools/Cepstrum/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
KINDS = ('FrameChecksum', 'FrameStageExport', 'InputConversionChecksum',
         'IntervalChecksum', 'PreviewChecksum', 'BoundedMatrixExport')
MATRIX = [{'name': k, 'workload': {'kind': k}} for k in KINDS]


def capture(mode):
    names = [f'Cepstrum.{op}.{k}' for k in KINDS for op in benchmark.OPERATIONS]
    if mode == 'allocation':
        names += [benchmark.CONTROL]
    metrics = ['wallClock', 'cpuTotal'] if mode == 'timing' else ['wallClock', *benchmark.DIAGNOSTICS]
    rows = []
    for name in names:
        values = []
        allocating = name == benchmark.CONTROL or '.Prepare.' in name or name.endswith(('FrameStageExport', 'BoundedMatrixExport'))
        for metric in metrics:
            maximum = 1 if allocating or metric in ('wallClock', 'cpuTotal') else 0
            values.append({'metric': {metric: {}}, 'scalingFactor': 1,
                           'statistics': {'histogram': {'_totalCount': 10, 'maxValue': maximum, 'counts': [10]}}})
        rows += [{'name': name, 'target': 'CepstrumBenchmarks'}, values]
    return {'results': rows}


def matrix():
    rows = []
    for name, (kind, precision, rate, count, hop, preview) in benchmark.expected_cases().items():
        export = kind == 'BoundedMatrixExport'
        frame_only = kind in ('FrameChecksum', 'FrameStageExport')
        conversion = kind == 'InputConversionChecksum'
        phases = 10000 // math.gcd(rate, 10000)
        config = {'schemaVersion': 1, 'inputPrecision': precision, 'hopSeconds': hop / 1000,
                  'preEmphasisFromHz': 50, 'previewHopLength': 10 * hop if preview else None,
                  'frame': {'schemaVersion': 1, 'definition': 'praat-7.0.02-power-cepstrum',
                            'sampleRate': 10000, 'precision': 'float64', 'pitchFloorHz': 60,
                            'frameLength': 1000, 'transformLength': 1024},
                  'conditioning': {'schemaVersion': 1, 'sourceSampleRate': rate, 'targetSampleRate': 10000,
                    'precision': 'float64', 'ratio': {'numerator': phases, 'denominator': rate // math.gcd(rate, 10000)},
                    'method': {'kind': 'streamingPreview', 'lobes': 16, 'cutoffFraction': .9} if preview else
                              {'kind': 'praat7WholeInterval', 'interpolationDepth': 50},
                    'preEmphasisFromHz': None, 'declaredInputBandwidthHz': rate / 2,
                    'requiredInputBandwidthHz': 5000, 'gainPolicy': 'none'}}
        identifier = 'praat-7.0.02-power-cepstrum' if frame_only else 'finite-fir-preview-cepstrogram' if preview else 'praat-7.0.02-cepstrogram'
        if conversion:
            frames, tail, memory = 0, 0, count * 8 if precision == 'float32' else 0
        elif frame_only:
            frames, tail, memory = 1, 0, 73600 + (count * 8 if precision == 'float32' else 0)
        else:
            duration = count // rate
            frames, tail = (duration * 1000 - 100) // hop + 1, 1 if preview else 0
            if preview:
                width = 2 * math.ceil(16 * rate / 10000) + 1
                memory = 73600 + 8 * (phases * width + 2 * width + 256 + 3000 + 256)
            else:
                fft = 1 << (count + 1999).bit_length()
                memory = 73600 + 8 * (count + duration * 10000 + 4 * fft + 2 + phases * 100 + 100 + 1000)
            memory += 32768 if precision == 'float32' else 0
        rows.append({'name': name, 'workload': {'name': name, 'kind': kind, 'configuration': config,
                     'inputSampleCount': count, 'inputChunkSamples': 256,
                     'matrixMaximumFrames': 500 if export else 0, 'matrixMaximumScalars': 256500 if export else 0,
                     'profileIdentities': [] if conversion else [{'identifier': {'name': identifier, 'version': 1}, 'sha256': '0' * 64}]},
                     'inputDurationSeconds': count / rate, 'preparedInputBytes': count * (4 if precision == 'float32' else 8),
                     'inputSHA256': '1' * 64, 'preparedBufferBytes': memory,
                     'emittedFrameCount': frames + tail, 'completeFrameCount': frames, 'unavailableFrameCount': tail,
                     'retainedFrameCount': frames + tail if export else 0,
                     'exportedScalarCount': frames * 513 if export else 4102 if kind == 'FrameStageExport' else 0,
                     'checksum': -1.0 if conversion else 1.0})
    return rows


class CepstrumBenchmarkTests(unittest.TestCase):
    def test_positive_control_requires_every_counter(self):
        good = capture('allocation')
        self.assertEqual(len(benchmark.validate_raw(good, MATRIX, 'allocation')), 13)
        for metric in benchmark.DIAGNOSTICS:
            bad = copy.deepcopy(good)
            for value in bad['results'][-1]:
                if metric in value['metric']:
                    value['statistics']['histogram']['maxValue'] = 0
            with self.assertRaisesRegex(ValueError, 'Unavailable'):
                benchmark.validate_raw(bad, MATRIX, 'allocation')

    def test_only_explicit_owned_exports_may_allocate(self):
        for i, kind in enumerate(KINDS):
            if kind in ('FrameStageExport', 'BoundedMatrixExport'):
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

    def test_complete_matrix_requires_precision_geometry_retention_memory_and_identity(self):
        good = matrix()
        self.assertEqual(len(benchmark.validate_matrix(good)), 38)
        for bad in (good[:-1], good + good[:1]):
            with self.assertRaises(ValueError): benchmark.validate_matrix(bad)
        for key, value in [('emittedFrameCount', 0), ('completeFrameCount', 0),
                           ('unavailableFrameCount', 1), ('retainedFrameCount', 1),
                           ('exportedScalarCount', 513), ('preparedInputBytes', 0),
                           ('preparedBufferBytes', 0), ('inputSHA256', 'x' * 64),
                           ('checksum', 0), ('checksum', float('nan'))]:
            bad = copy.deepcopy(good); bad[0][key] = value
            with self.assertRaises(ValueError): benchmark.validate_matrix(bad)
        for key, value in [('precision', 'float32'), ('pitchFloorHz', 75), ('transformLength', 1000)]:
            bad = copy.deepcopy(good); bad[0]['workload']['configuration']['frame'][key] = value
            with self.assertRaises(ValueError): benchmark.validate_matrix(bad)
        for key, value in [('inputPrecision', 'float64'), ('hopSeconds', .01), ('preEmphasisFromHz', None)]:
            bad = copy.deepcopy(good); bad[0]['workload']['configuration'][key] = value
            with self.assertRaises(ValueError): benchmark.validate_matrix(bad)
        bad = copy.deepcopy(good); bad[1]['inputSHA256'] = '2' * 64
        with self.assertRaisesRegex(ValueError, 'inconsistent PCM'): benchmark.validate_matrix(bad)
        bad = copy.deepcopy(good); bad[0]['workload']['profileIdentities'][0]['sha256'] = ''
        with self.assertRaisesRegex(ValueError, 'profile identity'): benchmark.validate_matrix(bad)
        bad = copy.deepcopy(good)
        row = next(r for r in bad if r['workload']['kind'] == 'BoundedMatrixExport')
        row['workload']['matrixMaximumFrames'] = 0
        with self.assertRaisesRegex(ValueError, 'retention budget'): benchmark.validate_matrix(bad)
