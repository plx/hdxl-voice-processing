"""Pulse performance receipts must retain input, coverage, and allocation evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('pulse_benchmark', ROOT / 'Tools/Pulses/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
MATRIX = [dict(name='borrowed', workload=dict(ownedSnapshot=False)),
          dict(name='owned', workload=dict(ownedSnapshot=True))]


def capture(mode):
    names = [f'Pulse.{op}.{r["name"]}' for r in MATRIX for op in benchmark.OPERATIONS]
    if mode == 'allocation': names.append(benchmark.CONTROL)
    metrics = ['wallClock', 'cpuTotal'] if mode == 'timing' else ['wallClock', *benchmark.DIAGNOSTICS]
    rows = []
    for name in names:
        allocating = name == benchmark.CONTROL or '.Prepare.' in name or name.endswith('.owned')
        rows += [dict(name=name, target='PulseBenchmarks'), [
            dict(metric={metric: {}}, scalingFactor=1, statistics=dict(histogram={
                '_totalCount': 10, 'maxValue': int(allocating or metric in ('wallClock','cpuTotal')), 'counts': [10]}))
            for metric in metrics]]
    return dict(results=rows)


class PulseBenchmarkTests(unittest.TestCase):
    def test_amortized_costs_do_not_claim_isolated_accepted_or_rejected_stage_times(self):
        matrix = [dict(name='example', inputDurationSeconds=.5, preparedBufferBytes=100,
            counts=dict(attempts=2, acceptedAttempts=1, rejectedAttempts=1, eligiblePeriods=0))]
        values = {'Pulse.Run.example - Time (wall clock)':250_000_000,
                  'Pulse.Prepare.example - Time (wall clock)':10_000}
        result = benchmark.operation_costs(matrix, values)['example']
        self.assertEqual(result['inputSecondsPerWallSecond'],2)
        self.assertEqual(result['amortizedNanosecondsPerAttempt'],125_000_000)
        matrix[0]['counts']['attempts'] = 0
        self.assertIsNone(benchmark.operation_costs(matrix,values)['example']['amortizedNanosecondsPerAttempt'])
        values['Pulse.Run.example - Time (wall clock)'] = 0
        with self.assertRaises(ValueError): benchmark.operation_costs(matrix,values)

    def test_matrix_covers_rates_frequencies_precision_delivery_stress_and_ownership(self):
        cases = benchmark.expected_cases()
        self.assertEqual(len(cases), 88)
        groups = [set(benchmark.expected_cases(shard)) for shard in benchmark.SHARDS]
        self.assertEqual([len(g) for g in groups], [16,16,16,32,4,4])
        self.assertEqual(set.union(*groups), set(cases))
        self.assertEqual(sum(map(len,groups)), len(cases))
        steady = {r['fixture'] for r in cases.values() if r['shard'].startswith('steady')}
        self.assertEqual(steady, {f'gaussian-{rate}-{hz}' for rate in (16000,44100,48000) for hz in (80,150,300,600)})
        self.assertEqual({r['support'] for r in cases.values()}, {'completeInterval','independentlyAnchoredBlock'})
        with self.assertRaises(ValueError): benchmark.expected_cases('unknown')

    def test_positive_controls_and_zero_heap_prepared_processing(self):
        self.assertEqual(len(benchmark.validate_raw(capture('allocation'), MATRIX, 'allocation')), 5)
        for metric in benchmark.DIAGNOSTICS:
            bad = capture('allocation')
            for row in bad['results'][-1]:
                if metric in row['metric']: row['statistics']['histogram']['maxValue'] = 0
            with self.assertRaisesRegex(ValueError, 'Unavailable'):
                benchmark.validate_raw(bad, MATRIX, 'allocation')
        for metric in benchmark.ALLOCATIONS:
            bad = capture('allocation')
            for row in bad['results'][3]:
                if metric in row['metric']: row['statistics']['histogram']['maxValue'] = 1
            with self.assertRaisesRegex(ValueError, 'Steady-state'):
                benchmark.validate_raw(bad, MATRIX, 'allocation')

    def test_distribution_coverage_sample_counts_and_units_fail_closed(self):
        for mode in ('timing','allocation'):
            benchmark.validate_raw(capture(mode), MATRIX, mode)
            mutations = [lambda r: r['results'].pop(), lambda r: r['results'].__setitem__(2,r['results'][0]),
                lambda r: r['results'][1].pop(), lambda r: r['results'][0].__setitem__('target','Wrong'),
                lambda r: r['results'][1][0].__setitem__('scalingFactor',100),
                lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('_totalCount',9),
                lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('counts',[-1,11]),
                lambda r: r['results'][1][0]['statistics']['histogram'].__setitem__('maxValue',0)]
            for mutate in mutations:
                bad = capture(mode); mutate(bad)
                with self.assertRaises(ValueError): benchmark.validate_raw(bad, MATRIX, mode)
        good = [dict(name=f'case - {metric}', value=3, unit='ns') for metric in ('Time (wall clock)','Time (total CPU)')]
        benchmark.validate_export(good, ['case'], 'timing')
        for bad in (good[:1], good+good, [{**good[0], 'unit':'ms'},good[1]], [{**good[0], 'value':float('nan')},good[1]]):
            with self.assertRaises(ValueError): benchmark.validate_export(bad,['case'],'timing')

    def test_captured_receipts_reject_changed_inputs_geometry_and_denominators(self):
        records = json.loads(CAPTURED)
        selected = {r['name']: benchmark.expected_cases()[r['name']] for r in records}
        with patch.object(benchmark, 'expected_cases', return_value=selected):
            benchmark.validate_matrix(records)
            mutations = [lambda r: r.pop(), lambda r: r.append(r[0]),
                lambda r: r[0]['workload'].__setitem__('chunkSamples',255),
                lambda r: r[0]['configuration'].__setitem__('pitchFloorHz',50),
                lambda r: r[0].__setitem__('f0FrameCount',0),
                lambda r: r[0].__setitem__('preparedBufferBytes',0),
                lambda r: r[0].__setitem__('maximumDependencyDelaySeconds',0),
                lambda r: r[0]['profileIdentity'].__setitem__('sha256','0'*64),
                lambda r: r[0]['f0ContourIdentity'].__setitem__('sha256','0'*64),
                lambda r: r[0].__setitem__('encodedInputSHA256','0'*64),
                lambda r: r[0].__setitem__('normalizedInputSHA256','0'*64),
                lambda r: r[0]['counts'].__setitem__('rejectedAttempts',0),
                lambda r: r[0]['counts'].__setitem__('eligiblePairs',999),
                lambda r: r[-1]['counts'].__setitem__('exportedRecords',0),
                lambda r: r[0].__setitem__('maximumReferenceErrorSamples',.1),
                lambda r: r[0].__setitem__('maximumAmplitudeBudgetFraction',2),
                lambda r: r[0].__setitem__('checksum',float('nan'))]
            for mutate in mutations:
                bad = copy.deepcopy(records); mutate(bad)
                with self.assertRaises(ValueError): benchmark.validate_matrix(bad)


# Captured metadata receipts exercise validation, not DSP expected answers or timings.
CAPTURED = r'''
[
  {
    "checksum": 124413.71058145634,
    "configuration": {
      "amplitudeDefinition": "hannRMSPointTwoNeighborPeriods",
      "arithmeticPrecision": "float64",
      "correlationDefinition": "observedPairsFusedDotScaleSubnormalProductFiniteLagTableRightNeighborPeak",
      "definition": "hdxl-acoustic-pulses-waveform-cc-v1",
      "inputPrecision": "float32",
      "interpolationDefinition": "threePointParabolaGeometricRangeFallback",
      "maximumAdjacentPeriodFactor": 1.3,
      "maximumPeriodSeconds": 0.02,
      "minimumPeriodSeconds": 0.0001,
      "minimumRelativeVariation": 1.4210854715202004e-14,
      "minimumReliableCurvature": 2.842170943040401e-14,
      "pitchCeilingHz": 1500,
      "pitchFloorHz": 20,
      "sampleRate": 16000,
      "schemaVersion": 1,
      "seedDefinition": "voicedIntervalMidpointAbsoluteExtremumParabola",
      "support": "completeInterval"
    },
    "counts": {
      "acceptedAttempts": 39,
      "attempts": 41,
      "availableAmplitudes": 37,
      "eligibleAttempts": 38,
      "eligiblePairs": 37,
      "eligiblePeriods": 38,
      "eligiblePulses": 39,
      "exportedRecords": 0,
      "rawPairs": 38,
      "rawPeriods": 39,
      "rawPulses": 40,
      "rejectedAttempts": 2,
      "runs": 1
    },
    "encodedInputSHA256": "e1f7f68229a6fe6fc2e3337f7e26864d696dba72e241fab1d9b6252314367cdc",
    "f0ContourIdentity": {
      "identifier": {
        "name": "hdxl-pulse-supplied-f0",
        "version": 1
      },
      "sha256": "28e26a10072d9d7728ec87bbfb511dfb17d3454334cd7f38f9c5c6237b072f01"
    },
    "f0FrameCount": 100,
    "fixtureJSONSHA256": "d0a96692fd7d8e9b7cce97590a896d7f329362300cc3d476a385d9a3cacee931",
    "inputDurationSeconds": 0.5,
    "inputSampleCount": 8000,
    "maximumAmplitudeBudgetFraction": 5.7897545662072586e-06,
    "maximumDependencyDelaySeconds": 0.25,
    "maximumReferenceErrorSamples": 0,
    "name": "gaussian-16000-80.float32.whole.borrowed",
    "normalizedInputSHA256": "3e5cb381cfee6188ec2f05752dae8ac63492574c73999e8fdaefa943fc58e649",
    "preparedBufferBytes": 1507168,
    "preparedInputBytes": 32000,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-acoustic-pulses-waveform-cc-v1-completeInterval",
        "version": 1
      },
      "sha256": "cce6ea57a7e401c95a8258589442a9306e3f28d879d10facac1d5e9e769bf5f5"
    },
    "workload": {
      "chunkSamples": 256,
      "fixture": "gaussian-16000-80",
      "maximumTrackingAttempts": 4096,
      "ownedSnapshot": false,
      "precision": "float32",
      "shard": "steady16000",
      "support": "completeInterval"
    },
    "preparedContourBytes": 800,
    "f0FirstCenterSeconds": 0.0025000000000000022,
    "f0StepSeconds": 0.005
  },
  {
    "checksum": 1535225.2123724371,
    "configuration": {
      "amplitudeDefinition": "hannRMSPointTwoNeighborPeriods",
      "arithmeticPrecision": "float64",
      "correlationDefinition": "observedPairsFusedDotScaleSubnormalProductFiniteLagTableRightNeighborPeak",
      "definition": "hdxl-acoustic-pulses-waveform-cc-v1",
      "inputPrecision": "float64",
      "interpolationDefinition": "threePointParabolaGeometricRangeFallback",
      "maximumAdjacentPeriodFactor": 1.3,
      "maximumPeriodSeconds": 0.02,
      "minimumPeriodSeconds": 0.0001,
      "minimumRelativeVariation": 1.4210854715202004e-14,
      "minimumReliableCurvature": 2.842170943040401e-14,
      "pitchCeilingHz": 1500,
      "pitchFloorHz": 20,
      "sampleRate": 16000,
      "schemaVersion": 1,
      "seedDefinition": "voicedIntervalMidpointAbsoluteExtremumParabola",
      "support": "independentlyAnchoredBlock"
    },
    "counts": {
      "acceptedAttempts": 3,
      "attempts": 74,
      "availableAmplitudes": 0,
      "eligibleAttempts": 3,
      "eligiblePairs": 0,
      "eligiblePeriods": 0,
      "eligiblePulses": 4,
      "exportedRecords": 0,
      "rawPairs": 2,
      "rawPeriods": 3,
      "rawPulses": 4,
      "rejectedAttempts": 71,
      "runs": 4
    },
    "encodedInputSHA256": "a505e8959788f8d211f55416dd4db74285af73e3a0f251facd7731d22701a62c",
    "f0ContourIdentity": {
      "identifier": {
        "name": "hdxl-pulse-supplied-f0",
        "version": 1
      },
      "sha256": "fc43364150862aaa3cee3eb5c9104a61e533c0af7e2a267900f66eb7a97f87e5"
    },
    "f0FrameCount": 100,
    "fixtureJSONSHA256": "91e6a62823a2880b9b3d73b3da5ff874ebc33b376409804ab164eb62897157de",
    "inputDurationSeconds": 0.5,
    "inputSampleCount": 8000,
    "maximumAmplitudeBudgetFraction": 0,
    "maximumDependencyDelaySeconds": 0.25,
    "maximumReferenceErrorSamples": 0,
    "name": "noise.float64.block.borrowed",
    "normalizedInputSHA256": "024f809d40d0d541a239e01afc8032bd2f76f1b7cfd5386c49a1aa9175eca9c3",
    "preparedBufferBytes": 1571168,
    "preparedInputBytes": 64000,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-acoustic-pulses-waveform-cc-v1-independentlyAnchoredBlock",
        "version": 1
      },
      "sha256": "c02639dfb2a4eae72dde237b9b20ec3ea02180de056701d9c4a352537a4782d2"
    },
    "workload": {
      "chunkSamples": 256,
      "fixture": "noise",
      "maximumTrackingAttempts": 4096,
      "ownedSnapshot": false,
      "precision": "float64",
      "shard": "stress",
      "support": "independentlyAnchoredBlock"
    },
    "preparedContourBytes": 800,
    "f0FirstCenterSeconds": 0.0025000000000000022,
    "f0StepSeconds": 0.005
  },
  {
    "checksum": 41833.41794331516,
    "configuration": {
      "amplitudeDefinition": "hannRMSPointTwoNeighborPeriods",
      "arithmeticPrecision": "float64",
      "correlationDefinition": "observedPairsFusedDotScaleSubnormalProductFiniteLagTableRightNeighborPeak",
      "definition": "hdxl-acoustic-pulses-waveform-cc-v1",
      "inputPrecision": "float64",
      "interpolationDefinition": "threePointParabolaGeometricRangeFallback",
      "maximumAdjacentPeriodFactor": 1.3,
      "maximumPeriodSeconds": 0.02,
      "minimumPeriodSeconds": 0.0001,
      "minimumRelativeVariation": 1.4210854715202004e-14,
      "minimumReliableCurvature": 2.842170943040401e-14,
      "pitchCeilingHz": 700,
      "pitchFloorHz": 20,
      "sampleRate": 44100,
      "schemaVersion": 1,
      "seedDefinition": "voicedIntervalMidpointAbsoluteExtremumParabola",
      "support": "completeInterval"
    },
    "counts": {
      "acceptedAttempts": 83,
      "attempts": 83,
      "availableAmplitudes": 80,
      "eligibleAttempts": 81,
      "eligiblePairs": 80,
      "eligiblePeriods": 81,
      "eligiblePulses": 82,
      "exportedRecords": 0,
      "rawPairs": 82,
      "rawPeriods": 83,
      "rawPulses": 84,
      "rejectedAttempts": 0,
      "runs": 1
    },
    "encodedInputSHA256": "5002e8477b8db6a3d2607384c3d90e3e55d7cb7b6ebcff285d5c1db42d83e9d2",
    "f0ContourIdentity": {
      "identifier": {
        "name": "hdxl-pulse-supplied-f0",
        "version": 1
      },
      "sha256": "79d3a3d2a71b30f0d18a0de7d0eda5e25638bc0f736227601089e1f470dc8b11"
    },
    "f0FrameCount": 95,
    "fixtureJSONSHA256": "a69cfe79bfe7fdade478926b7e8cd5570bd218da15147c5df594369af9c3835a",
    "inputDurationSeconds": 0.5,
    "inputSampleCount": 22050,
    "maximumAmplitudeBudgetFraction": 4.988932838572907e-06,
    "maximumDependencyDelaySeconds": 0.25,
    "maximumReferenceErrorSamples": 0,
    "name": "speech-bl01-vowel-a.float64.whole.borrowed",
    "normalizedInputSHA256": "ee80515ac759c42375fc3bcaff729d994f0f3cacda6fdd87193eedf93c6db887",
    "preparedBufferBytes": 1638704,
    "preparedInputBytes": 176400,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-acoustic-pulses-waveform-cc-v1-completeInterval",
        "version": 1
      },
      "sha256": "471f6c3ebe53398835619d222fc44f5943b4cd95d29a090b3b4743e946e3809e"
    },
    "workload": {
      "chunkSamples": 256,
      "fixture": "speech-bl01-vowel-a",
      "maximumTrackingAttempts": 4096,
      "ownedSnapshot": false,
      "precision": "float64",
      "shard": "vowel",
      "support": "completeInterval"
    },
    "preparedContourBytes": 760,
    "f0FirstCenterSeconds": 0.014999999999999984,
    "f0StepSeconds": 0.005
  },
  {
    "checksum": 141139.47100523429,
    "configuration": {
      "amplitudeDefinition": "hannRMSPointTwoNeighborPeriods",
      "arithmeticPrecision": "float64",
      "correlationDefinition": "observedPairsFusedDotScaleSubnormalProductFiniteLagTableRightNeighborPeak",
      "definition": "hdxl-acoustic-pulses-waveform-cc-v1",
      "inputPrecision": "float64",
      "interpolationDefinition": "threePointParabolaGeometricRangeFallback",
      "maximumAdjacentPeriodFactor": 1.3,
      "maximumPeriodSeconds": 0.02,
      "minimumPeriodSeconds": 0.0001,
      "minimumRelativeVariation": 1.4210854715202004e-14,
      "minimumReliableCurvature": 2.842170943040401e-14,
      "pitchCeilingHz": 1500,
      "pitchFloorHz": 20,
      "sampleRate": 48000,
      "schemaVersion": 1,
      "seedDefinition": "voicedIntervalMidpointAbsoluteExtremumParabola",
      "support": "independentlyAnchoredBlock"
    },
    "counts": {
      "acceptedAttempts": 74,
      "attempts": 76,
      "availableAmplitudes": 72,
      "eligibleAttempts": 73,
      "eligiblePairs": 72,
      "eligiblePeriods": 73,
      "eligiblePulses": 74,
      "exportedRecords": 373,
      "rawPairs": 73,
      "rawPeriods": 74,
      "rawPulses": 75,
      "rejectedAttempts": 2,
      "runs": 1
    },
    "encodedInputSHA256": "f88b0a89ffa4d65265356287685605d98eab1aa3a13b0f9b51364aee444b4756",
    "f0ContourIdentity": {
      "identifier": {
        "name": "hdxl-pulse-supplied-f0",
        "version": 1
      },
      "sha256": "ab4c85a58febd486a9090fcae865b4b1ecda46d0caccd9d09218a94867a08dbf"
    },
    "f0FrameCount": 100,
    "fixtureJSONSHA256": "7f8c11bb34373fcb00cb75c158e618c64b8dc7488935f6d2a8c68d199c8927f4",
    "inputDurationSeconds": 0.5,
    "inputSampleCount": 24000,
    "maximumAmplitudeBudgetFraction": 5.789754603040484e-06,
    "maximumDependencyDelaySeconds": 0.25,
    "maximumReferenceErrorSamples": 0,
    "name": "gaussian-48000-150.float64.block.owned",
    "normalizedInputSHA256": "88986ef1d871321557a1e50994d93f559361b00656cae6e2a208fab0b6d56c91",
    "preparedBufferBytes": 1850208,
    "preparedInputBytes": 192000,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-acoustic-pulses-waveform-cc-v1-independentlyAnchoredBlock",
        "version": 1
      },
      "sha256": "2d5b7cedf1fbc4337222c57afbde5f407477d90b7741089902630f2312d70292"
    },
    "workload": {
      "chunkSamples": 256,
      "fixture": "gaussian-48000-150",
      "maximumTrackingAttempts": 4096,
      "ownedSnapshot": true,
      "precision": "float64",
      "shard": "export",
      "support": "independentlyAnchoredBlock"
    },
    "preparedContourBytes": 800,
    "f0FirstCenterSeconds": 0.0025000000000000022,
    "f0StepSeconds": 0.005
  }
]
'''

if __name__ == "__main__":
    unittest.main()
