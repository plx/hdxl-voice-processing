"""Receipt validation controls using two captured native rows, not DSP goldens."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('swipe_workloads_tested', ROOT / 'Tools/SWIPE/workloads.py')
workloads = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workloads)


class SWIPEWorkloadTests(unittest.TestCase):
    def test_closed_matrix_and_literal_maximum(self):
        cases = workloads.expected_cases()
        self.assertEqual(len(cases), 44)
        all_names = []
        for shard in workloads.SHARDS:
            rows = workloads.expected_cases(shard)
            self.assertTrue(rows)
            all_names.extend(rows)
        self.assertEqual(len(all_names), 44)
        self.assertEqual(set(all_names), set(cases))
        for precision, expected_bytes in [('float32', 24713192), ('float64', 26286056)]:
            name = f'MaximumGeometry.{precision}.192000Hz.n136833.f20-48000.h10.r192'
            row = cases[name]
            self.assertEqual(row['layout']['requiredSampleCount'], 131072)
            self.assertEqual(workloads.expected_geometry(row, 'SWIPEPrime')['preparedBufferBytes'],
                             expected_bytes)
            self.assertEqual(workloads.expected_geometry(row, 'YINFFT')['supportSamples'], 19201)
        with self.assertRaises(ValueError):
            workloads.expected_cases('unknown')

    def test_captured_native_pair_and_corruption_controls(self):
        rows = json.loads(CAPTURED)
        name = rows[0]['workload']['name']
        expected = {name: workloads.expected_cases()[name]}
        with patch.object(workloads, 'expected_cases', return_value=expected):
            self.assertEqual(workloads.validate_matrix(rows), rows)
            workloads.validate_matrix(list(reversed(rows)))
            controls = {
                'missing row': lambda r: r.pop(),
                'extra row': lambda r: r.append(copy.deepcopy(r[0])),
                'duplicate pair': lambda r: r.__setitem__(1, copy.deepcopy(r[0])),
                'unknown algorithm': lambda r: r[0].__setitem__('algorithm', 'YINScalar'),
                'extra field': lambda r: r[0].__setitem__('undeclared', 1),
                'missing geometry': lambda r: r[0].pop('supportSamples'),
                'wrong frame bound': lambda r: r[0].__setitem__('supportSamples', 65536),
                'boolean count': lambda r: r[0].__setitem__('candidateCount', True),
                'wrong buffer bytes': lambda r: r[0].__setitem__('preparedBufferBytes', 909223),
                'wrong delay': lambda r: r[0].__setitem__('algorithmicDelaySeconds', 0),
                'wrong grid': lambda r: r[0]['windowLengths'].pop(),
                'wrong profile': lambda r: r[0]['workload']['configuration'].__setitem__('pitchFloorHz', 81),
                'boolean schema': lambda r: r[0]['workload']['configuration'].__setitem__('schemaVersion', True),
                'noninteger input count': lambda r: r[0]['workload'].__setitem__('inputSampleCount', 32000.0),
                'wrong fingerprint': lambda r: r[0]['profileIdentity'].__setitem__('sha256', 'a' * 64),
                'wrong baseline profile': lambda r: r[1]['workload']['baseline']['estimator'].__setitem__('differenceBackend', 'scalar'),
                'different PCM': lambda r: r[1].__setitem__('inputSHA256', 'a' * 64),
                'same wrong PCM': lambda r: [x.__setitem__('inputSHA256', 'a' * 64) for x in r],
                'malformed PCM hash': lambda r: r[0].__setitem__('inputSHA256', 'xyz'),
                'wrong coverage': lambda r: r[0]['counts'].__setitem__('full', 187),
                'boolean coverage': lambda r: r[0]['counts'].__setitem__('partial', True),
                'fake export': lambda r: r[0]['counts'].__setitem__('exportedScalarSlots', 1),
                'fake encoded bytes': lambda r: r[0]['counts'].__setitem__('exportedJSONBytes', 1),
                'nonfinite checksum': lambda r: r[0].__setitem__('checksum', float('nan')),
                'boolean checksum': lambda r: r[0].__setitem__('checksum', True),
                'missing probe': lambda r: r[0]['probes'].pop(),
                'reordered probes': lambda r: r[0]['probes'].reverse(),
                'shifted probe': lambda r: r[0]['probes'][1].__setitem__('startSample', 0),
                'wrong probe support': lambda r: r[0]['probes'][0].__setitem__('observedSamples', 1),
                'missing estimate': lambda r: r[0]['probes'][0].pop('frequencyHz'),
                'nonfinite strength': lambda r: r[0]['probes'][0].__setitem__('strength', float('inf')),
                'out of range': lambda r: r[0]['probes'][0].__setitem__('frequencyHz', 1000),
                'contradictory status': lambda r: r[0]['probes'][0].__setitem__('status', 'unvoiced'),
            }
            for label, corrupt in controls.items():
                with self.subTest(control=label):
                    changed = copy.deepcopy(rows)
                    corrupt(changed)
                    with self.assertRaises(ValueError):
                        workloads.validate_matrix(changed)

    def test_profile_comparison_keeps_numeric_types_explicit(self):
        self.assertFalse(workloads.same_value(True, 1))
        self.assertFalse(workloads.same_value(1.0, 1))
        self.assertTrue(workloads.same_value(1, 1.0))
        self.assertFalse(workloads.same_value({'x': 1, 'y': 2}, {'x': 1}))
        self.assertFalse(workloads.same_value(float('nan'), 1.0))


# Captured release metadata from the 16 kHz, Float64, 80...400 Hz, 10 ms case.
# These are receipt fixtures only; numerical oracle verification is separate.
CAPTURED = r'''
[
  {
    "algorithm": "SWIPEPrime",
    "algorithmicDelaySeconds": 0.064,
    "candidateCount": 224,
    "checksum": 410622.8919625187,
    "counts": {
      "exportedJSONBytes": 0,
      "exportedScalarSlots": 0,
      "full": 188,
      "partial": 1,
      "unavailable": 1,
      "uncertain": 0,
      "unvoiced": 0,
      "voiced": 188
    },
    "erbBinCount": 333,
    "hopSamples": 160,
    "inputSHA256": "e9f17a433d047150606f9a54f1a81728d4ea4e5074bf53dfb11fe1492f01b44b",
    "preparedBufferBytes": 909224,
    "preparedInputBytes": 256000,
    "probes": [
      {
        "frameIndex": 0,
        "frequencyHz": 125.03433759031464,
        "observedSamples": 2048,
        "startSample": 0,
        "status": "voiced",
        "strength": 0.917215545067526
      },
      {
        "frameIndex": 93,
        "frequencyHz": 125.0343375973106,
        "observedSamples": 2048,
        "startSample": 14880,
        "status": "voiced",
        "strength": 0.917215524456025
      },
      {
        "frameIndex": 187,
        "frequencyHz": 125.0343374256139,
        "observedSamples": 2048,
        "startSample": 29920,
        "status": "voiced",
        "strength": 0.9172154676358574
      }
    ],
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-swipe-prime-centered-2008",
        "version": 1
      },
      "sha256": "d06a3fa065b15643c5f31cff1e74fe55dabb2d2f366c87122a4f053aacfa08f6"
    },
    "supportSamples": 2048,
    "supportSeconds": 0.128,
    "windowLengths": [
      256,
      512,
      1024,
      2048
    ],
    "workload": {
      "baseline": {
        "estimator": {
          "arithmeticPrecision": "float64",
          "definition": "hdxl-yin-fixed-time-2002-steps2to5",
          "differenceBackend": "fft",
          "hopLength": 160,
          "inputPrecision": "float64",
          "integrationLength": 200,
          "interpolation": "cmndOrdinateRawDifferencePeriod",
          "neighboringTimeRefinement": "disabled",
          "normalization": "observedPeak",
          "partialWindowPolicy": "emitUnavailable",
          "pitchCeilingHz": 400,
          "pitchFloorHz": 80,
          "rangeBoundaryToleranceSamples": 0.000002,
          "sampleRate": 16000,
          "schemaVersion": 1,
          "silenceRMSThreshold": 1e-7,
          "supportPolicy": "fixedIntegrationPlusMaximumLagAndNeighbor",
          "threshold": 0.1
        },
        "schemaVersion": 1,
        "tracker": null
      },
      "chunkSamples": 256,
      "configuration": {
        "arithmeticPrecision": "float64",
        "bandPolicy": "wholeERBGridThroughNyquistIncludingPartialLobes",
        "candidateGrid": "logarithmicWithExactEndpoints",
        "candidatesPerOctave": 96,
        "definition": "hdxl-swipe-prime-centered-2008",
        "erbMapping": "glasbergMoore229Hz21Point4",
        "erbStep": 0.1,
        "gridEndpointRelativeTolerance": 1e-12,
        "hopLength": 160,
        "inputPrecision": "float64",
        "kernel": "firstAndPrimeHarmonicsPositivePartNorm",
        "normalization": "observedPeakAndWholeBandLoudnessL2",
        "partialWindowPolicy": "emitUnavailable",
        "pitchCeilingHz": 400,
        "pitchFloorHz": 80,
        "refinement": "concavePeriodVertexWithinNeighbors",
        "sampleRate": 16000,
        "schemaVersion": 1,
        "selection": "maximumStrengthLowestFrequencyTie",
        "silenceRMSThreshold": 1e-7,
        "spectrumInterpolation": "linearMagnitudeThenSquareRoot",
        "strengthThreshold": 0.2,
        "supportPolicy": "longestRequiredObservedWindow",
        "windowPolicy": "centeredPeriodicHannEightPeriodsLogBlend"
      },
      "inputSampleCount": 32000,
      "kind": "Harmonic",
      "name": "Harmonic.float64.16000Hz.n32000.f80-400.h10.r96",
      "requestedHopMilliseconds": 10
    }
  },
  {
    "algorithm": "YINFFT",
    "algorithmicDelaySeconds": 0.01253125,
    "candidateCount": 0,
    "checksum": 104665.82680887227,
    "counts": {
      "exportedJSONBytes": 0,
      "exportedScalarSlots": 0,
      "full": 198,
      "partial": 1,
      "unavailable": 1,
      "uncertain": 0,
      "unvoiced": 0,
      "voiced": 198
    },
    "erbBinCount": 0,
    "hopSamples": 160,
    "inputSHA256": "e9f17a433d047150606f9a54f1a81728d4ea4e5074bf53dfb11fe1492f01b44b",
    "preparedBufferBytes": 70888,
    "preparedInputBytes": 256000,
    "probes": [
      {
        "frameIndex": 0,
        "frequencyHz": 124.99505350782269,
        "observedSamples": 401,
        "startSample": 0,
        "status": "voiced",
        "strength": 1
      },
      {
        "frameIndex": 98,
        "frequencyHz": 125.00207675265406,
        "observedSamples": 401,
        "startSample": 15680,
        "status": "voiced",
        "strength": 1
      },
      {
        "frameIndex": 197,
        "frequencyHz": 124.9995706060577,
        "observedSamples": 401,
        "startSample": 31520,
        "status": "voiced",
        "strength": 1
      }
    ],
    "profileIdentity": {
      "identifier": {
        "name": "yin-estimator-and-optional-tracker",
        "version": 1
      },
      "sha256": "ec6c4d3ec4b338dc185171faf79d34783ef261d9eadbb225e7bdbe58fd8f58ff"
    },
    "supportSamples": 401,
    "supportSeconds": 0.0250625,
    "windowLengths": [],
    "workload": {
      "baseline": {
        "estimator": {
          "arithmeticPrecision": "float64",
          "definition": "hdxl-yin-fixed-time-2002-steps2to5",
          "differenceBackend": "fft",
          "hopLength": 160,
          "inputPrecision": "float64",
          "integrationLength": 200,
          "interpolation": "cmndOrdinateRawDifferencePeriod",
          "neighboringTimeRefinement": "disabled",
          "normalization": "observedPeak",
          "partialWindowPolicy": "emitUnavailable",
          "pitchCeilingHz": 400,
          "pitchFloorHz": 80,
          "rangeBoundaryToleranceSamples": 0.000002,
          "sampleRate": 16000,
          "schemaVersion": 1,
          "silenceRMSThreshold": 1e-7,
          "supportPolicy": "fixedIntegrationPlusMaximumLagAndNeighbor",
          "threshold": 0.1
        },
        "schemaVersion": 1,
        "tracker": null
      },
      "chunkSamples": 256,
      "configuration": {
        "arithmeticPrecision": "float64",
        "bandPolicy": "wholeERBGridThroughNyquistIncludingPartialLobes",
        "candidateGrid": "logarithmicWithExactEndpoints",
        "candidatesPerOctave": 96,
        "definition": "hdxl-swipe-prime-centered-2008",
        "erbMapping": "glasbergMoore229Hz21Point4",
        "erbStep": 0.1,
        "gridEndpointRelativeTolerance": 1e-12,
        "hopLength": 160,
        "inputPrecision": "float64",
        "kernel": "firstAndPrimeHarmonicsPositivePartNorm",
        "normalization": "observedPeakAndWholeBandLoudnessL2",
        "partialWindowPolicy": "emitUnavailable",
        "pitchCeilingHz": 400,
        "pitchFloorHz": 80,
        "refinement": "concavePeriodVertexWithinNeighbors",
        "sampleRate": 16000,
        "schemaVersion": 1,
        "selection": "maximumStrengthLowestFrequencyTie",
        "silenceRMSThreshold": 1e-7,
        "spectrumInterpolation": "linearMagnitudeThenSquareRoot",
        "strengthThreshold": 0.2,
        "supportPolicy": "longestRequiredObservedWindow",
        "windowPolicy": "centeredPeriodicHannEightPeriodsLogBlend"
      },
      "inputSampleCount": 32000,
      "kind": "Harmonic",
      "name": "Harmonic.float64.16000Hz.n32000.f80-400.h10.r96",
      "requestedHopMilliseconds": 10
    }
  }
]
'''
