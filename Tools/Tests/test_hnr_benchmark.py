"""Reject incomplete or misleading HNR performance evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('hnr_benchmark', ROOT / 'Tools/HNR/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
KINDS = ('Harmonic', 'LowFloor', 'Silence', 'Noise', 'OwnedDiagnostics')
MATRIX = [{'name': k, 'workload': {'kind': k}} for k in KINDS]


def capture(mode):
    names = [f'HNR.{op}.{k}' for k in KINDS for op in benchmark.OPERATIONS]
    if mode == 'allocation': names += [benchmark.CONTROL]
    metrics = ['wallClock', 'cpuTotal'] if mode == 'timing' else ['wallClock', *benchmark.DIAGNOSTICS]
    rows = []
    for name in names:
        allocating = name == benchmark.CONTROL or '.Prepare.' in name or name.endswith('OwnedDiagnostics')
        values = []
        for metric in metrics:
            maximum = 1 if allocating or metric in ('wallClock', 'cpuTotal') else 0
            values.append({'metric': {metric: {}}, 'scalingFactor': 1,
                'statistics': {'histogram': {'_totalCount': 10, 'maxValue': maximum, 'counts': [10]}}})
        rows += [{'name': name, 'target': 'HNRBenchmarks'}, values]
    return {'results': rows}


class HNRBenchmarkTests(unittest.TestCase):
    def test_matrix_covers_requested_cross_product_and_support_stresses(self):
        cases=benchmark.expected_cases()
        self.assertEqual(len(cases),208)
        groups=[set(benchmark.expected_cases(shard)) for shard in benchmark.SHARDS]
        self.assertEqual([len(g) for g in groups],[32,32,32,32,32,32,8,8])
        self.assertEqual(set.union(*groups),set(cases))
        self.assertEqual(sum(map(len,groups)),len(cases))
        primary=[x for x in cases.values() if x['kind']=='Harmonic']
        self.assertEqual({(x['method'],x['rate'],x['periods'],x['floor'],x['hop'],x['precision'],x['normalization']) for x in primary},
            {(m,r,p,f,h,s,n) for m in ('ac','cc') for r in (16000,44100,48000)
             for p in (4.5,6.) for f in (60,75) for h in (5,10)
             for s in ('float32','float64') for n in ('whole','causal')})
        self.assertEqual(max(x['causal'] for x in cases.values()),28800)
        self.assertEqual({x['count']/x['rate'] for x in cases.values() if x['kind'] in ('Silence','Noise')},{5})
        with self.assertRaisesRegex(ValueError,'Unknown'): benchmark.expected_cases('missing')

    def test_positive_control_and_prepared_heap_maxima(self):
        good = capture('allocation')
        self.assertEqual(len(benchmark.validate_raw(good,MATRIX,'allocation')),11)
        for metric in benchmark.DIAGNOSTICS:
            bad = copy.deepcopy(good)
            for item in bad['results'][-1]:
                if metric in item['metric']: item['statistics']['histogram']['maxValue']=0
            with self.assertRaisesRegex(ValueError,'Unavailable'): benchmark.validate_raw(bad,MATRIX,'allocation')
        for i,kind in enumerate(KINDS):
            if kind == 'OwnedDiagnostics': continue
            for metric in benchmark.ALLOCATIONS:
                bad = capture('allocation')
                for item in bad['results'][4*i+3]:
                    if metric in item['metric']: item['statistics']['histogram']['maxValue']=1
                with self.assertRaisesRegex(ValueError,'Steady-state'): benchmark.validate_raw(bad,MATRIX,'allocation')

    def test_missing_or_malformed_distributions_and_units_fail(self):
        for mode in ('timing','allocation'):
            good = capture(mode); benchmark.validate_raw(good,MATRIX,mode)
            changes = [lambda r:r['results'].pop(), lambda r:r['results'].__setitem__(2,r['results'][0]),
                lambda r:r['results'][1].pop(), lambda r:r['results'][0].__setitem__('target','Wrong'),
                lambda r:r['results'][1][0].__setitem__('scalingFactor',100),
                lambda r:r['results'][1][0]['statistics']['histogram'].__setitem__('_totalCount',9),
                lambda r:r['results'][1][0]['statistics']['histogram'].__setitem__('counts',[-1,11]),
                lambda r:r['results'][1][0]['statistics']['histogram'].__setitem__('maxValue',0)]
            for change in changes:
                bad=copy.deepcopy(good);change(bad)
                with self.assertRaises(ValueError):benchmark.validate_raw(bad,MATRIX,mode)
        rows=[{'name':f'case - {m}','value':3,'unit':'ns'} for m in ('Time (wall clock)','Time (total CPU)')]
        benchmark.validate_export(rows,['case'],'timing')
        for bad in (rows[:1],rows+rows,[{**rows[0],'unit':'ms'},rows[1]],[{**rows[0],'value':float('nan')},rows[1]]):
            with self.assertRaises(ValueError):benchmark.validate_export(bad,['case'],'timing')


    def test_captured_receipts_reject_corrupted_contracts(self):
        examples=json.loads(CAPTURED)
        expected={r['name']:benchmark.expected_cases()[r['name']] for r in examples}
        with patch.object(benchmark,'expected_cases',return_value=expected):
            benchmark.validate_matrix(examples)
            changes=[lambda r:r.pop(),lambda r:r.append(r[0]),
                lambda r:r[0]['workload'].__setitem__('chunkSamples',255),
                lambda r:r[0]['workload']['configuration'].__setitem__('silenceThreshold',.2),
                lambda r:r[0].__setitem__('windowSamples',0),
                lambda r:r[0].__setitem__('preparedBufferBytes',0),
                lambda r:r[0].__setitem__('candidateRecordStride',128),
                lambda r:r[0].__setitem__('transformLength',8192),
                lambda r:r[0].__setitem__('inputSHA256','x'*64),
                lambda r:r[0]['profileIdentity'].__setitem__('sha256','0'*64),
                lambda r:r[0].__setitem__('completeFrames',0),
                lambda r:r[1].__setitem__('partialFrames',0),
                lambda r:r[0].__setitem__('availableFrames',0),
                lambda r:r[0].__setitem__('maximumDependencyDelaySeconds',100),
                lambda r:r[0].__setitem__('reportingLimitFrames',-1),
                lambda r:r[0].__setitem__('checksum',float('nan')),
                lambda r:r[-1].__setitem__('exportedScalars',0),
                lambda r:r[-1].__setitem__('exportedByteChecksum',0)]
            for change in changes:
                bad=copy.deepcopy(examples);change(bad)
                with self.assertRaises(ValueError): benchmark.validate_matrix(bad)



SPEC_STAGE = importlib.util.spec_from_file_location('hnr_stage_benchmark', ROOT / 'Tools/HNR/stage_benchmark.py')
stage = importlib.util.module_from_spec(SPEC_STAGE)
SPEC_STAGE.loader.exec_module(stage)


class HNRStageEvidenceTests(unittest.TestCase):
    def receipt(self):
        # Synthetic positive receipt for schema/accounting tests, never timing evidence.
        import hashlib
        name,row=next(iter(benchmark.expected_cases('ac16000').items()))
        profile=benchmark.expected_profile(row)
        digest=hashlib.sha256(benchmark.canonical_module.canonical(profile)).hexdigest()
        full=51
        identity=dict(identifier=dict(name='hdxl-hnr-ac-wholeIntervalMeanRemovedPeak',version=1),sha256=digest)
        trials=[]
        for i in range(5):
            for mode in ('disabled','detailed'):
                values={k:[] for k in stage.STAGES}
                if mode=='detailed':
                    values.update(hnrNormalization=[1000],analysisFrame=[500]*full,hnr=[400]*full,
                        hnrWindow=[80]*full,hnrCorrelation=[100]*full,hnrPeriodSearch=[100]*full,fft=[30]*(2*full))
                trials.append(dict(configuration=profile,profileIdentity=identity,inputSampleCount=6400,
                    trial=i,mode=mode,nanoseconds=100000,checksum=123,completeFrames=full,stageNanoseconds=values))
        return {name:row},dict(schemaVersion=1,definition='hnr-worker-stage-clock-probe-v1',
            limitations='synthetic instrumented overhead example',trials=trials)

    def test_exact_stage_coverage_and_nested_inclusive_accounting(self):
        expected,good=self.receipt()
        with patch.object(stage.benchmark,'expected_cases',return_value=expected):
            result=stage.validate(good,16000)
            self.assertEqual(next(iter(result.values()))['fft']['sampleCount'],510)
            changes=[lambda r:r['trials'].pop(),lambda r:r['trials'].append(r['trials'][0]),
                lambda r:r['trials'][1].__setitem__('checksum',124),
                lambda r:r['trials'][1].__setitem__('nanoseconds',100),
                lambda r:r['trials'][1].__setitem__('completeFrames',52),
                lambda r:r['trials'][1]['configuration'].__setitem__('silenceThreshold',0),
                lambda r:r['trials'][1]['profileIdentity'].__setitem__('sha256','0'*64),
                lambda r:r['trials'][1]['stageNanoseconds']['fft'].pop(),
                lambda r:r['trials'][1]['stageNanoseconds']['fft'].__setitem__(0,10000),
                lambda r:r['trials'][1]['stageNanoseconds']['hnrPeriodSearch'].__setitem__(0,0),
                lambda r:r['trials'][0]['stageNanoseconds']['hnr'].append(1)]
            for change in changes:
                bad=copy.deepcopy(good);change(bad)
                with self.assertRaises(ValueError): stage.validate(bad,16000)


# Captured release metadata checks receipt validation, not numerical reference values.
CAPTURED = r'''
[
  {
    "availableFrames": 51,
    "candidateRecordStride": 152,
    "checksum": 124464.50539287216,
    "completeFrames": 51,
    "emittedFrames": 51,
    "exportedByteChecksum": 0,
    "exportedCandidates": 0,
    "exportedJSONBytes": 0,
    "exportedScalars": 0,
    "finiteFrames": 51,
    "hopSamples": 80,
    "inputDurationSeconds": 0.4,
    "inputSHA256": "b70409fd58294d18b6044b42c0ce76afb42778c134d42ba8e3fd313478f5ae57",
    "maximumCandidateLag": 268,
    "maximumCorrelationLag": 599,
    "maximumDependencyDelaySeconds": 0.2,
    "name": "Harmonic.ac.float32.16000Hz.p4.5.f60.h5.whole",
    "nominalSupportSeconds": 0.15,
    "normalizationWindowSamples": 6400,
    "numericalZeroNoiseFrames": 0,
    "partialFrames": 0,
    "preparedBufferBytes": 284632,
    "preparedInputBytes": 25600,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-hnr-ac-wholeIntervalMeanRemovedPeak",
        "version": 1
      },
      "sha256": "d818f761e5130e51ddb24d7a482fe9d6ba3e495912c45accf835c232ea9693c3"
    },
    "reportingLimitFrames": 0,
    "transformLength": 4096,
    "unavailableFrames": 0,
    "windowSamples": 2398,
    "workload": {
      "chunkSamples": 256,
      "configuration": {
        "arithmeticPrecision": "float64",
        "arithmeticScaling": "framePeakScaledBinary64WithSeparateSilenceReference",
        "frameGrid": "centeredWholeIntervalBinary64FusedStep",
        "hopSeconds": 0.005,
        "inputPrecision": "float32",
        "interpolation": "sinc700SymmetricRaisedCosineDepthPlusHalf",
        "method": "ac",
        "minimumPeakCurvature": 2.842170943040401e-14,
        "normalization": "wholeIntervalMeanRemovedPeak",
        "overshoot": "reciprocalAboveOne",
        "partialWindowPolicy": "emitUnavailable",
        "peakResolution": "positiveLocalMaximumCurvature128Binary64Ulps-v1",
        "periodsPerWindow": 4.5,
        "pitchFloorHz": 60,
        "reportingDecibelLimit": 150,
        "reportingPeriodicityLimit": 1e-15,
        "sampleRate": 16000,
        "schemaVersion": 1,
        "silenceThreshold": 0.1,
        "window": "pitchGaussianNPlusOne"
      },
      "inputSampleCount": 6400,
      "kind": "Harmonic",
      "name": "Harmonic.ac.float32.16000Hz.p4.5.f60.h5.whole"
    }
  },
  {
    "availableFrames": 62,
    "candidateRecordStride": 152,
    "checksum": 94489.63969303905,
    "completeFrames": 62,
    "emittedFrames": 63,
    "exportedByteChecksum": 0,
    "exportedCandidates": 0,
    "exportedJSONBytes": 0,
    "exportedScalars": 0,
    "finiteFrames": 62,
    "hopSamples": 80,
    "inputDurationSeconds": 0.4,
    "inputSHA256": "b70409fd58294d18b6044b42c0ce76afb42778c134d42ba8e3fd313478f5ae57",
    "maximumCandidateLag": 268,
    "maximumCorrelationLag": 1198,
    "maximumDependencyDelaySeconds": 0.04584375,
    "name": "Harmonic.cc.float32.16000Hz.p4.5.f60.h5.causal",
    "nominalSupportSeconds": 0.09166666666666666,
    "normalizationWindowSamples": 1467,
    "numericalZeroNoiseFrames": 0,
    "partialFrames": 1,
    "preparedBufferBytes": 268671,
    "preparedInputBytes": 25600,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-hnr-cc-causalWindowMeanRemovedPeak",
        "version": 1
      },
      "sha256": "c7d7f1c2b98fd96b3287167e25d2905511d23d55c90ea4d131cb0a91ead3fa0a"
    },
    "reportingLimitFrames": 0,
    "transformLength": 4096,
    "unavailableFrames": 1,
    "windowSamples": 1198,
    "workload": {
      "chunkSamples": 256,
      "configuration": {
        "arithmeticPrecision": "float64",
        "arithmeticScaling": "framePeakScaledBinary64WithSeparateSilenceReference",
        "frameGrid": "causalAcquiredWindowCenterExactBinary64StepAccumulator",
        "hopSeconds": 0.005,
        "inputPrecision": "float32",
        "interpolation": "sinc700SymmetricRaisedCosineDepthPlusHalf",
        "method": "cc",
        "minimumPeakCurvature": 2.842170943040401e-14,
        "normalization": "causalWindowMeanRemovedPeak",
        "overshoot": "reciprocalAboveOne",
        "partialWindowPolicy": "emitUnavailable",
        "peakResolution": "positiveLocalMaximumCurvature128Binary64Ulps-v1",
        "periodsPerWindow": 4.5,
        "pitchFloorHz": 60,
        "reportingDecibelLimit": 150,
        "reportingPeriodicityLimit": 1e-15,
        "sampleRate": 16000,
        "schemaVersion": 1,
        "silenceThreshold": 0.1,
        "window": "rectangularForwardPair"
      },
      "inputSampleCount": 6400,
      "kind": "Harmonic",
      "name": "Harmonic.cc.float32.16000Hz.p4.5.f60.h5.causal"
    }
  },
  {
    "availableFrames": 2,
    "candidateRecordStride": 152,
    "checksum": 143828.31081283762,
    "completeFrames": 4,
    "emittedFrames": 5,
    "exportedByteChecksum": 0,
    "exportedCandidates": 0,
    "exportedJSONBytes": 0,
    "exportedScalars": 0,
    "finiteFrames": 2,
    "hopSamples": 240,
    "inputDurationSeconds": 0.615,
    "inputSHA256": "40804bf1f55187f0a8fd37defc1aaffe66f640eb83f4eb65d335fcc910465749",
    "maximumCandidateLag": 2401,
    "maximumCorrelationLag": 7199,
    "maximumDependencyDelaySeconds": 0.3,
    "name": "LowFloor.ac.float32.48000Hz.p6.0.f20.h5.causal",
    "nominalSupportSeconds": 0.6,
    "normalizationWindowSamples": 28800,
    "numericalZeroNoiseFrames": 0,
    "partialFrames": 1,
    "preparedBufferBytes": 3867184,
    "preparedInputBytes": 118080,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-hnr-ac-causalWindowMeanRemovedPeak",
        "version": 1
      },
      "sha256": "60d71e9fc3b328c243c9bb6b0c5449c25b9b809e7f8b7622c2d8d31427eaf551"
    },
    "reportingLimitFrames": 0,
    "transformLength": 65536,
    "unavailableFrames": 3,
    "windowSamples": 28798,
    "workload": {
      "chunkSamples": 256,
      "configuration": {
        "arithmeticPrecision": "float64",
        "arithmeticScaling": "framePeakScaledBinary64WithSeparateSilenceReference",
        "frameGrid": "causalAcquiredWindowCenterExactBinary64StepAccumulator",
        "hopSeconds": 0.005,
        "inputPrecision": "float32",
        "interpolation": "sinc700SymmetricRaisedCosineDepthPlusHalf",
        "method": "ac",
        "minimumPeakCurvature": 2.842170943040401e-14,
        "normalization": "causalWindowMeanRemovedPeak",
        "overshoot": "reciprocalAboveOne",
        "partialWindowPolicy": "emitUnavailable",
        "peakResolution": "positiveLocalMaximumCurvature128Binary64Ulps-v1",
        "periodsPerWindow": 6,
        "pitchFloorHz": 20,
        "reportingDecibelLimit": 150,
        "reportingPeriodicityLimit": 1e-15,
        "sampleRate": 48000,
        "schemaVersion": 1,
        "silenceThreshold": 0.1,
        "window": "pitchGaussianNPlusOne"
      },
      "inputSampleCount": 29520,
      "kind": "LowFloor",
      "name": "LowFloor.ac.float32.48000Hz.p6.0.f20.h5.causal"
    }
  },
  {
    "availableFrames": 0,
    "candidateRecordStride": 152,
    "checksum": 5475743,
    "completeFrames": 977,
    "emittedFrames": 978,
    "exportedByteChecksum": 0,
    "exportedCandidates": 0,
    "exportedJSONBytes": 0,
    "exportedScalars": 0,
    "finiteFrames": 0,
    "hopSamples": 240,
    "inputDurationSeconds": 5,
    "inputSHA256": "124617c1f65e92d3bc895fbd869e4bb16a30754b198f59e6e973949b9aaa1b01",
    "maximumCandidateLag": 801,
    "maximumCorrelationLag": 4798,
    "maximumDependencyDelaySeconds": 0.058333333333333334,
    "name": "Silence.cc.float64.48000Hz.p6.0.f60.h5.causal",
    "nominalSupportSeconds": 0.11666666666666667,
    "normalizationWindowSamples": 5600,
    "numericalZeroNoiseFrames": 0,
    "partialFrames": 1,
    "preparedBufferBytes": 1073071,
    "preparedInputBytes": 1920000,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-hnr-cc-causalWindowMeanRemovedPeak",
        "version": 1
      },
      "sha256": "b828d5ed9e3bbb6949c94fa660d66fec7043007b8637449ac3bae03c62853c9f"
    },
    "reportingLimitFrames": 0,
    "transformLength": 16384,
    "unavailableFrames": 978,
    "windowSamples": 4798,
    "workload": {
      "chunkSamples": 256,
      "configuration": {
        "arithmeticPrecision": "float64",
        "arithmeticScaling": "framePeakScaledBinary64WithSeparateSilenceReference",
        "frameGrid": "causalAcquiredWindowCenterExactBinary64StepAccumulator",
        "hopSeconds": 0.005,
        "inputPrecision": "float64",
        "interpolation": "sinc700SymmetricRaisedCosineDepthPlusHalf",
        "method": "cc",
        "minimumPeakCurvature": 2.842170943040401e-14,
        "normalization": "causalWindowMeanRemovedPeak",
        "overshoot": "reciprocalAboveOne",
        "partialWindowPolicy": "emitUnavailable",
        "peakResolution": "positiveLocalMaximumCurvature128Binary64Ulps-v1",
        "periodsPerWindow": 6,
        "pitchFloorHz": 60,
        "reportingDecibelLimit": 150,
        "reportingPeriodicityLimit": 1e-15,
        "sampleRate": 48000,
        "schemaVersion": 1,
        "silenceThreshold": 0.1,
        "window": "rectangularForwardPair"
      },
      "inputSampleCount": 240000,
      "kind": "Silence",
      "name": "Silence.cc.float64.48000Hz.p6.0.f60.h5.causal"
    }
  },
  {
    "availableFrames": 961,
    "candidateRecordStride": 152,
    "checksum": 9447110.984645886,
    "completeFrames": 961,
    "emittedFrames": 962,
    "exportedByteChecksum": 0,
    "exportedCandidates": 0,
    "exportedJSONBytes": 0,
    "exportedScalars": 0,
    "finiteFrames": 961,
    "hopSamples": 240,
    "inputDurationSeconds": 5,
    "inputSHA256": "7e9f74124efee56155682e2e7313f0e181c758ba77903e783cbc565690f9ceab",
    "maximumCandidateLag": 801,
    "maximumCorrelationLag": 2399,
    "maximumDependencyDelaySeconds": 0.1,
    "name": "Noise.ac.float64.48000Hz.p6.0.f60.h5.causal",
    "nominalSupportSeconds": 0.2,
    "normalizationWindowSamples": 9600,
    "numericalZeroNoiseFrames": 0,
    "partialFrames": 1,
    "preparedBufferBytes": 1147504,
    "preparedInputBytes": 1920000,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-hnr-ac-causalWindowMeanRemovedPeak",
        "version": 1
      },
      "sha256": "b9e7c5f5e3468731c70ca76785e3c6de736470c0f58d2bb6536af51e5be7b0db"
    },
    "reportingLimitFrames": 0,
    "transformLength": 16384,
    "unavailableFrames": 1,
    "windowSamples": 9598,
    "workload": {
      "chunkSamples": 256,
      "configuration": {
        "arithmeticPrecision": "float64",
        "arithmeticScaling": "framePeakScaledBinary64WithSeparateSilenceReference",
        "frameGrid": "causalAcquiredWindowCenterExactBinary64StepAccumulator",
        "hopSeconds": 0.005,
        "inputPrecision": "float64",
        "interpolation": "sinc700SymmetricRaisedCosineDepthPlusHalf",
        "method": "ac",
        "minimumPeakCurvature": 2.842170943040401e-14,
        "normalization": "causalWindowMeanRemovedPeak",
        "overshoot": "reciprocalAboveOne",
        "partialWindowPolicy": "emitUnavailable",
        "peakResolution": "positiveLocalMaximumCurvature128Binary64Ulps-v1",
        "periodsPerWindow": 6,
        "pitchFloorHz": 60,
        "reportingDecibelLimit": 150,
        "reportingPeriodicityLimit": 1e-15,
        "sampleRate": 48000,
        "schemaVersion": 1,
        "silenceThreshold": 0.1,
        "window": "pitchGaussianNPlusOne"
      },
      "inputSampleCount": 240000,
      "kind": "Noise",
      "name": "Noise.ac.float64.48000Hz.p6.0.f60.h5.causal"
    }
  },
  {
    "availableFrames": 28,
    "candidateRecordStride": 152,
    "checksum": 28013716.277327783,
    "completeFrames": 28,
    "emittedFrames": 28,
    "exportedByteChecksum": 1681715,
    "exportedCandidates": 28,
    "exportedJSONBytes": 20110,
    "exportedScalars": 282184,
    "finiteFrames": 28,
    "hopSamples": 480,
    "inputDurationSeconds": 0.4,
    "inputSHA256": "0ce7a234e114fbea94c57cf0df7aa4a350426f2fab625cdbbc4211a0ae0f79eb",
    "maximumCandidateLag": 641,
    "maximumCorrelationLag": 1439,
    "maximumDependencyDelaySeconds": 0.2,
    "name": "OwnedDiagnostics.ac.float32.48000Hz.p4.5.f75.h10.whole",
    "nominalSupportSeconds": 0.12,
    "normalizationWindowSamples": 19200,
    "numericalZeroNoiseFrames": 0,
    "partialFrames": 0,
    "preparedBufferBytes": 632624,
    "preparedInputBytes": 76800,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-hnr-ac-wholeIntervalMeanRemovedPeak",
        "version": 1
      },
      "sha256": "d2588fadedf2c8599a6953298c0b9fe285defa9ad045d37cd8c17c674f0cab65"
    },
    "reportingLimitFrames": 0,
    "transformLength": 8192,
    "unavailableFrames": 0,
    "windowSamples": 5758,
    "workload": {
      "chunkSamples": 256,
      "configuration": {
        "arithmeticPrecision": "float64",
        "arithmeticScaling": "framePeakScaledBinary64WithSeparateSilenceReference",
        "frameGrid": "centeredWholeIntervalBinary64FusedStep",
        "hopSeconds": 0.01,
        "inputPrecision": "float32",
        "interpolation": "sinc700SymmetricRaisedCosineDepthPlusHalf",
        "method": "ac",
        "minimumPeakCurvature": 2.842170943040401e-14,
        "normalization": "wholeIntervalMeanRemovedPeak",
        "overshoot": "reciprocalAboveOne",
        "partialWindowPolicy": "emitUnavailable",
        "peakResolution": "positiveLocalMaximumCurvature128Binary64Ulps-v1",
        "periodsPerWindow": 4.5,
        "pitchFloorHz": 75,
        "reportingDecibelLimit": 150,
        "reportingPeriodicityLimit": 1e-15,
        "sampleRate": 48000,
        "schemaVersion": 1,
        "silenceThreshold": 0.1,
        "window": "pitchGaussianNPlusOne"
      },
      "inputSampleCount": 19200,
      "kind": "OwnedDiagnostics",
      "name": "OwnedDiagnostics.ac.float32.48000Hz.p4.5.f75.h10.whole"
    }
  },
  {
    "availableFrames": 33,
    "candidateRecordStride": 152,
    "checksum": 132903.0351119251,
    "completeFrames": 33,
    "emittedFrames": 34,
    "exportedByteChecksum": 2058142,
    "exportedCandidates": 33,
    "exportedJSONBytes": 24878,
    "exportedScalars": 189981,
    "finiteFrames": 33,
    "hopSamples": 480,
    "inputDurationSeconds": 0.4,
    "inputSHA256": "0ce7a234e114fbea94c57cf0df7aa4a350426f2fab625cdbbc4211a0ae0f79eb",
    "maximumCandidateLag": 641,
    "maximumCorrelationLag": 2878,
    "maximumDependencyDelaySeconds": 0.03666666666666667,
    "name": "OwnedDiagnostics.cc.float32.48000Hz.p4.5.f75.h10.causal",
    "nominalSupportSeconds": 0.07333333333333333,
    "normalizationWindowSamples": 3520,
    "numericalZeroNoiseFrames": 0,
    "partialFrames": 1,
    "preparedBufferBytes": 578991,
    "preparedInputBytes": 76800,
    "profileIdentity": {
      "identifier": {
        "name": "hdxl-hnr-cc-causalWindowMeanRemovedPeak",
        "version": 1
      },
      "sha256": "b4e81fb07b11bcec66f3bd29e46493e6ae16de0a4294c28be759e37d0516f63c"
    },
    "reportingLimitFrames": 0,
    "transformLength": 8192,
    "unavailableFrames": 1,
    "windowSamples": 2878,
    "workload": {
      "chunkSamples": 256,
      "configuration": {
        "arithmeticPrecision": "float64",
        "arithmeticScaling": "framePeakScaledBinary64WithSeparateSilenceReference",
        "frameGrid": "causalAcquiredWindowCenterExactBinary64StepAccumulator",
        "hopSeconds": 0.01,
        "inputPrecision": "float32",
        "interpolation": "sinc700SymmetricRaisedCosineDepthPlusHalf",
        "method": "cc",
        "minimumPeakCurvature": 2.842170943040401e-14,
        "normalization": "causalWindowMeanRemovedPeak",
        "overshoot": "reciprocalAboveOne",
        "partialWindowPolicy": "emitUnavailable",
        "peakResolution": "positiveLocalMaximumCurvature128Binary64Ulps-v1",
        "periodsPerWindow": 4.5,
        "pitchFloorHz": 75,
        "reportingDecibelLimit": 150,
        "reportingPeriodicityLimit": 1e-15,
        "sampleRate": 48000,
        "schemaVersion": 1,
        "silenceThreshold": 0.1,
        "window": "rectangularForwardPair"
      },
      "inputSampleCount": 19200,
      "kind": "OwnedDiagnostics",
      "name": "OwnedDiagnostics.cc.float32.48000Hz.p4.5.f75.h10.causal"
    }
  }
]
'''
