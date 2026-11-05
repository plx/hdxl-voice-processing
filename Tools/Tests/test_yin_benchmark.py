"""Reject incomplete or misleading YIN performance evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('yin_benchmark', ROOT / 'Tools/YIN/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
KINDS = ('Harmonic', 'LowFloor', 'MaximumSupport', 'Silence', 'Noise', 'OwnedDiagnostics')
MATRIX = [{'name': k, 'workload': {'kind': k}} for k in KINDS]


def capture(mode):
    names = [f'YIN.{op}.{k}' for k in KINDS for op in benchmark.OPERATIONS]
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
        rows += [{'name': name, 'target': 'YINBenchmarks'}, values]
    return {'results': rows}


class YINBenchmarkTests(unittest.TestCase):
    def test_matrix_covers_requested_cross_product_and_support_stresses(self):
        cases = benchmark.expected_cases()
        self.assertEqual(len(cases), 82)
        groups = [set(benchmark.expected_cases(shard)) for shard in benchmark.SHARDS]
        self.assertEqual([len(g) for g in groups], [16,16,16,16,8,4,4,2])
        self.assertEqual(set.union(*groups), set(cases))
        self.assertEqual(sum(map(len, groups)), len(cases))
        primary = [x for x in cases.values() if x['kind']=='Harmonic' and x['precision']=='float64']
        self.assertEqual({(x['rate'],x['floor'],x['ceiling'],x['hop'],x['backend'],x['tracking']) for x in primary},
            {(r,f,c,h,b,t) for r in (16000,44100,48000) for f,c in ((50,700),(25,2000))
             for h in (5,10) for b in ('scalar','fft') for t in (False,True)})
        self.assertEqual(max(x['support'] for x in cases.values()),25985)
        self.assertEqual({x['hopSamples'] for x in primary if x['rate']==44100}, {221,441})
        self.assertEqual({x['count']/x['rate'] for x in cases.values() if x['kind'] in ('Silence','Noise')},{30})
        with self.assertRaisesRegex(ValueError,'Unknown'): benchmark.expected_cases('missing')

    def test_positive_control_and_prepared_heap_maxima(self):
        good = capture('allocation')
        self.assertEqual(len(benchmark.validate_raw(good,MATRIX,'allocation')),13)
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
                lambda r:r[0]['workload']['profile']['estimator'].__setitem__('threshold',.2),
                lambda r:r[0].__setitem__('supportSamples',0),lambda r:r[0].__setitem__('preparedBufferBytes',0),
                lambda r:r[0].__setitem__('fftLength',8192),lambda r:r[0].__setitem__('inputSHA256','x'*64),
                lambda r:r[0]['profileIdentity'].__setitem__('sha256','0'*64),
                lambda r:r[0].__setitem__('fullFrames',0),lambda r:r[0].__setitem__('partialFrames',0),
                lambda r:r[0].__setitem__('trackedFrames',99999),lambda r:r[0].__setitem__('voicedFrames',0),
                lambda r:r[0].__setitem__('maximumDependencyDelaySeconds',100),
                lambda r:r[0].__setitem__('scalarFallbackFrames',-1),
                lambda r:r[0].__setitem__('checksum',float('nan')),
                lambda r:r[-1].__setitem__('exportedScalars',0),lambda r:r[-1].__setitem__('exportedByteChecksum',0)]
            for change in changes:
                bad=copy.deepcopy(examples);change(bad)
                with self.assertRaises(ValueError):benchmark.validate_matrix(bad)


# Captured release workload metadata: two scalar/FFT harmonic cases and two owned
# exports. These validate receipt handling, not algorithm numerical goldens.
CAPTURED = '[{"algorithmicDelaySeconds":0.02003125,"candidateRecordStride":56,"changedSelections":0,"checksum":302087.9998133193,"directlyRecomputedLags":0,"emittedFrames":393,"estimatorIdentity":{"identifier":{"name":"hdxl-yin-fixed-time-2002-steps2to5","version":1},"sha256":"35b8d10256b2cc55781e2e89911b6b7b1e00be38aa32aad58342eda738c913ce"},"exportedByteChecksum":0,"exportedCandidates":0,"exportedJSONBytes":0,"exportedScalars":0,"fftLength":0,"fullFrames":392,"hopSamples":80,"inputDurationSeconds":2,"inputSHA256":"e9f17a433d047150606f9a54f1a81728d4ea4e5074bf53dfb11fe1492f01b44b","integrationLength":320,"maximumDependencyDelaySeconds":0,"maximumRawDelaySeconds":0.02003125,"name":"Harmonic.float64.16000Hz.n32000.f50-700.h5.w320.scalar.track0","partialFrames":1,"preparedBufferBytes":42408,"preparedInputBytes":256000,"profileIdentity":{"identifier":{"name":"yin-estimator-and-optional-tracker","version":1},"sha256":"f4459911483093f440e984118a6549c5e3529d48cc0d715d9b93d651174cb49f"},"scalarFallbackFrames":0,"supportDurationSeconds":0.0400625,"supportSamples":641,"trackedFrames":0,"unavailableFrames":1,"uncertainFrames":0,"unvoicedFrames":0,"voicedFrames":392,"workload":{"chunkSamples":256,"inputSampleCount":32000,"kind":"Harmonic","name":"Harmonic.float64.16000Hz.n32000.f50-700.h5.w320.scalar.track0","profile":{"estimator":{"arithmeticPrecision":"float64","definition":"hdxl-yin-fixed-time-2002-steps2to5","differenceBackend":"scalar","hopLength":80,"inputPrecision":"float64","integrationLength":320,"interpolation":"cmndOrdinateRawDifferencePeriod","neighboringTimeRefinement":"disabled","normalization":"observedPeak","partialWindowPolicy":"emitUnavailable","pitchCeilingHz":700,"pitchFloorHz":50,"rangeBoundaryToleranceSamples":2e-06,"sampleRate":16000,"schemaVersion":1,"silenceRMSThreshold":1e-07,"supportPolicy":"fixedIntegrationPlusMaximumLagAndNeighbor","threshold":0.1},"schemaVersion":1,"tracker":null},"requestedHopMilliseconds":5}},{"algorithmicDelaySeconds":0.02003125,"candidateRecordStride":56,"changedSelections":0,"checksum":302087.9998133193,"directlyRecomputedLags":4312,"emittedFrames":393,"estimatorIdentity":{"identifier":{"name":"hdxl-yin-fixed-time-2002-steps2to5","version":1},"sha256":"73a1f03161f16a6a73508dcbdb8084cafdafecfaf4a418def65dbd2043d56165"},"exportedByteChecksum":0,"exportedCandidates":0,"exportedJSONBytes":0,"exportedScalars":0,"fftLength":1024,"fullFrames":392,"hopSamples":80,"inputDurationSeconds":2,"inputSHA256":"e9f17a433d047150606f9a54f1a81728d4ea4e5074bf53dfb11fe1492f01b44b","integrationLength":320,"maximumDependencyDelaySeconds":0,"maximumRawDelaySeconds":0.02003125,"name":"Harmonic.float64.16000Hz.n32000.f50-700.h5.w320.fft.track0","partialFrames":1,"preparedBufferBytes":91096,"preparedInputBytes":256000,"profileIdentity":{"identifier":{"name":"yin-estimator-and-optional-tracker","version":1},"sha256":"e642597fa9e55396d0c861a1dfdf67b27b2be15eedbd861040ff58f8d27e1048"},"scalarFallbackFrames":0,"supportDurationSeconds":0.0400625,"supportSamples":641,"trackedFrames":0,"unavailableFrames":1,"uncertainFrames":0,"unvoicedFrames":0,"voicedFrames":392,"workload":{"chunkSamples":256,"inputSampleCount":32000,"kind":"Harmonic","name":"Harmonic.float64.16000Hz.n32000.f50-700.h5.w320.fft.track0","profile":{"estimator":{"arithmeticPrecision":"float64","definition":"hdxl-yin-fixed-time-2002-steps2to5","differenceBackend":"fft","hopLength":80,"inputPrecision":"float64","integrationLength":320,"interpolation":"cmndOrdinateRawDifferencePeriod","neighboringTimeRefinement":"disabled","normalization":"observedPeak","partialWindowPolicy":"emitUnavailable","pitchCeilingHz":700,"pitchFloorHz":50,"rangeBoundaryToleranceSamples":2e-06,"sampleRate":16000,"schemaVersion":1,"silenceRMSThreshold":1e-07,"supportPolicy":"fixedIntegrationPlusMaximumLagAndNeighbor","threshold":0.1},"schemaVersion":1,"tracker":null},"requestedHopMilliseconds":5}},{"algorithmicDelaySeconds":0.020010416666666666,"candidateRecordStride":56,"changedSelections":0,"checksum":171741735.9636298,"directlyRecomputedLags":2156,"emittedFrames":197,"estimatorIdentity":{"identifier":{"name":"hdxl-yin-fixed-time-2002-steps2to5","version":1},"sha256":"799d56c2959d7b5ca2b081aca1aec840ead4cc5a68d3b812b4f466a9270f38eb"},"exportedByteChecksum":22748572,"exportedCandidates":392,"exportedJSONBytes":275361,"exportedScalars":377104,"fftLength":4096,"fullFrames":196,"hopSamples":480,"inputDurationSeconds":2,"inputSHA256":"f254fe719a592ba27c220245f9627f65ec9113e011daa41bf8a5789623455116","integrationLength":960,"maximumDependencyDelaySeconds":0.9950104166666667,"maximumRawDelaySeconds":0.020010416666666666,"name":"OwnedDiagnostics.float32.48000Hz.n96000.f50-700.h10.w960.fft.track1","partialFrames":1,"preparedBufferBytes":290748,"preparedInputBytes":384000,"profileIdentity":{"identifier":{"name":"yin-estimator-and-optional-tracker","version":1},"sha256":"a848efc7bb81c618ff36d1fd10766086d92a51dabd94d6c32f51ff575030c530"},"scalarFallbackFrames":0,"supportDurationSeconds":0.04002083333333333,"supportSamples":1921,"trackedFrames":197,"trackerIdentity":{"identifier":{"name":"causal-yin-candidate-continuity","version":1},"sha256":"47ace377edb5f68cc0a27f8ce952b835cb6c2c58d6929448e8dc49a23e0fe8f2"},"unavailableFrames":1,"uncertainFrames":0,"unvoicedFrames":0,"voicedFrames":196,"workload":{"chunkSamples":256,"inputSampleCount":96000,"kind":"OwnedDiagnostics","name":"OwnedDiagnostics.float32.48000Hz.n96000.f50-700.h10.w960.fft.track1","profile":{"estimator":{"arithmeticPrecision":"float64","definition":"hdxl-yin-fixed-time-2002-steps2to5","differenceBackend":"fft","hopLength":480,"inputPrecision":"float32","integrationLength":960,"interpolation":"cmndOrdinateRawDifferencePeriod","neighboringTimeRefinement":"disabled","normalization":"observedPeak","partialWindowPolicy":"emitUnavailable","pitchCeilingHz":700,"pitchFloorHz":50,"rangeBoundaryToleranceSamples":2e-06,"sampleRate":48000,"schemaVersion":1,"silenceRMSThreshold":1e-07,"supportPolicy":"fixedIntegrationPlusMaximumLagAndNeighbor","threshold":0.1},"schemaVersion":1,"tracker":{"continuityWeight":0.05,"definition":"causal-yin-candidate-continuity","schemaVersion":1}},"requestedHopMilliseconds":10}},{"algorithmicDelaySeconds":0.020010416666666666,"candidateRecordStride":56,"changedSelections":0,"checksum":171741736.7855043,"directlyRecomputedLags":2156,"emittedFrames":197,"estimatorIdentity":{"identifier":{"name":"hdxl-yin-fixed-time-2002-steps2to5","version":1},"sha256":"c6886721d7a035cb2bc916e01c15b6deb81e717b378452c67254b540d3e3c333"},"exportedByteChecksum":22688070,"exportedCandidates":392,"exportedJSONBytes":275285,"exportedScalars":377104,"fftLength":4096,"fullFrames":196,"hopSamples":480,"inputDurationSeconds":2,"inputSHA256":"dac93751ad84de35e52d7570b662019135a921a8f18457f20df7dea5daa7b8bc","integrationLength":960,"maximumDependencyDelaySeconds":0.9950104166666667,"maximumRawDelaySeconds":0.020010416666666666,"name":"OwnedDiagnostics.float64.48000Hz.n96000.f50-700.h10.w960.fft.track1","partialFrames":1,"preparedBufferBytes":313800,"preparedInputBytes":768000,"profileIdentity":{"identifier":{"name":"yin-estimator-and-optional-tracker","version":1},"sha256":"257a822625dadc9e0682f5515b6bbcda975f23f2fdea769a854f69be869d080d"},"scalarFallbackFrames":0,"supportDurationSeconds":0.04002083333333333,"supportSamples":1921,"trackedFrames":197,"trackerIdentity":{"identifier":{"name":"causal-yin-candidate-continuity","version":1},"sha256":"47ace377edb5f68cc0a27f8ce952b835cb6c2c58d6929448e8dc49a23e0fe8f2"},"unavailableFrames":1,"uncertainFrames":0,"unvoicedFrames":0,"voicedFrames":196,"workload":{"chunkSamples":256,"inputSampleCount":96000,"kind":"OwnedDiagnostics","name":"OwnedDiagnostics.float64.48000Hz.n96000.f50-700.h10.w960.fft.track1","profile":{"estimator":{"arithmeticPrecision":"float64","definition":"hdxl-yin-fixed-time-2002-steps2to5","differenceBackend":"fft","hopLength":480,"inputPrecision":"float64","integrationLength":960,"interpolation":"cmndOrdinateRawDifferencePeriod","neighboringTimeRefinement":"disabled","normalization":"observedPeak","partialWindowPolicy":"emitUnavailable","pitchCeilingHz":700,"pitchFloorHz":50,"rangeBoundaryToleranceSamples":2e-06,"sampleRate":48000,"schemaVersion":1,"silenceRMSThreshold":1e-07,"supportPolicy":"fixedIntegrationPlusMaximumLagAndNeighbor","threshold":0.1},"schemaVersion":1,"tracker":{"continuityWeight":0.05,"definition":"causal-yin-candidate-continuity","schemaVersion":1}},"requestedHopMilliseconds":10}}]'
