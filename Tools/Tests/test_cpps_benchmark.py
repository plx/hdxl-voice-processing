"""Guard CPPS evidence coverage and allocation exemptions."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('cpps_benchmark', ROOT / 'Tools/CPPS/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
KINDS = ('OwnedDiagnostics', 'IntervalCPPS', 'PreviewCPPS')
MATRIX = [{'name': k, 'workload': {'kind': k}} for k in KINDS]


def capture(mode):
    names = [f'CPPS.{op}.{k}' for k in KINDS for op in benchmark.OPERATIONS]
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
        rows += [{'name': name, 'target': 'CPPSBenchmarks'}, values]
    return {'results': rows}


class CPPSBenchmarkTests(unittest.TestCase):
    def test_positive_control_requires_every_counter(self):
        good = capture('allocation')
        self.assertEqual(len(benchmark.validate_raw(good, MATRIX, 'allocation')), 7)
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

    def test_shards_partition_all_requested_axes(self):
        all_cases = benchmark.expected_cases()
        self.assertEqual(len(all_cases), 87)
        parts = [benchmark.expected_cases(shard) for shard in benchmark.SHARDS]
        self.assertEqual(sum(map(len, parts)), 87)
        self.assertEqual(set().union(*(set(p) for p in parts)), set(all_cases))
        self.assertEqual([len(p) for p in parts], [6] * 12 + [15])
        self.assertEqual({r['window'] for r in all_cases.values()}, {1, 2, 3, 4, 5})
        primary = [r for r in all_cases.values() if r['shard'] != 'variants']
        actual = {(r['hop'], r['time'], r['quefrency'], r['window']) for r in primary}
        from itertools import product
        self.assertEqual(actual, set(product((2, 5, 10, 30), (10, 20, 50), (1, 5), (1, 3, 5))))
        for bad in ('', 'h3-w1', 'all'):
            with self.assertRaises(ValueError): benchmark.expected_cases(bad)
        with self.assertRaisesRegex(ValueError, 'coverage'):
            benchmark.validate_matrix([])

    def test_captured_swift_evidence_rejects_geometry_identity_and_coverage_changes(self):
        # Real checker output: disabled temporal smoothing, whole Float PCM, and
        # pretrend owned export. No implementation-derived numerical goldens.
        examples = json.loads(r'''[{"availableFrameCount":197,"checksum":3043.809711891652,"emittedFrameCount":198,"exportedScalarCount":0,"fitPointCount":512,"inputSHA256":"0436923454bc86af92326075a12d4553b117e11d3ec780d38eecec5f28f55e68","maximumContributingFrameCount":32,"maximumReportedDelaySeconds":0.066,"name":"PreviewCPPS.float64.16000Hz.6s.h30.t10.q1.w1.pre0","preparedInputBytes":768000,"preparedScalarBytes":170280,"rollingAvailableQueryCount":197,"rollingFrameCapacity":36,"rollingRecordBytes":2592,"slopeEvaluationsPerFit":261121,"smoothingFrameCapacity":1,"smoothingLookaheadFrames":0,"smoothingLookaheadSeconds":0,"smoothingRecordBytes":450,"smoothingScalarBytes":65616,"unavailableFrameCount":1,"verificationChunkSamples":63,"verificationMaximumReportedDelaySeconds":0.055375,"workload":{"inputChunkSamples":256,"inputDurationSeconds":6,"inputSampleCount":96000,"kind":"PreviewCPPS","name":"PreviewCPPS.float64.16000Hz.6s.h30.t10.q1.w1.pre0","profile":{"cepstrogram":{"conditioning":{"declaredInputBandwidthHz":8000,"gainPolicy":"none","method":{"cutoffFraction":0.9,"kind":"streamingPreview","lobes":16},"preEmphasisFromHz":null,"precision":"float64","ratio":{"denominator":8,"numerator":5},"requiredInputBandwidthHz":5000,"schemaVersion":1,"sourceSampleRate":16000,"targetSampleRate":10000},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"hopSeconds":0.03,"inputPrecision":"float64","preEmphasisFromHz":50,"previewHopLength":300,"schemaVersion":1},"schemaVersion":1,"settings":{"definition":"praat7002InterpolatedPower","edgePolicy":"normalizeAvailableSupport","pitchTolerance":0.05,"prominence":{"fitEndSeconds":0,"fitMethod":"praat7002Robust","fitStartSeconds":0.001,"interpolation":"parabolic","pitchCeilingHz":330,"pitchFloorHz":60,"schemaVersion":1},"quefrencyWindowSeconds":0.001,"schemaVersion":1,"subtractTrendBeforeSmoothing":false,"timeWindowSeconds":0.01}},"profileIdentity":{"identifier":{"name":"finite-fir-preview-cpps","version":1},"sha256":"16a434f6194add6a1212b3fa397a4d47f254262fab72489a7ed2c4c89bf2c169"},"shard":"h30-w1","statistic":{"aggregation":"rollingFrameMean","measurement":{"cepstrogram":{"conditioning":{"declaredInputBandwidthHz":8000,"gainPolicy":"none","method":{"cutoffFraction":0.9,"kind":"streamingPreview","lobes":16},"preEmphasisFromHz":null,"precision":"float64","ratio":{"denominator":8,"numerator":5},"requiredInputBandwidthHz":5000,"schemaVersion":1,"sourceSampleRate":16000,"targetSampleRate":10000},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"hopSeconds":0.03,"inputPrecision":"float64","preEmphasisFromHz":50,"previewHopLength":300,"schemaVersion":1},"schemaVersion":1,"settings":{"definition":"praat7002InterpolatedPower","edgePolicy":"normalizeAvailableSupport","pitchTolerance":0.05,"prominence":{"fitEndSeconds":0,"fitMethod":"praat7002Robust","fitStartSeconds":0.001,"interpolation":"parabolic","pitchCeilingHz":330,"pitchFloorHz":60,"schemaVersion":1},"quefrencyWindowSeconds":0.001,"schemaVersion":1,"subtractTrendBeforeSmoothing":false,"timeWindowSeconds":0.01}},"population":"allEligible","provenances":[],"rollingWindowSeconds":1,"schemaVersion":1,"selection":{"combination":"all","rejectedTags":[],"selectionSources":[]}},"statisticIdentity":{"identifier":{"name":"cpps-allEligible-rollingFrameMean","version":1},"sha256":"5192dae673dace579f2372c0eda35e2f9dbb96c6481c2d39b6abc1a04d6860f7"}}},{"availableFrameCount":2951,"checksum":46557.69464876456,"emittedFrameCount":2951,"exportedScalarCount":0,"fitPointCount":512,"inputSHA256":"3bd8b561bfc97d44b2a47f1fc4d02c87a0cd865e51c646a0fb5d64eb89ce4578","maximumContributingFrameCount":1476,"maximumReportedDelaySeconds":3,"name":"IntervalCPPS.float32.16000Hz.6s.h2.t10.q1.w3.pre0","preparedInputBytes":384000,"preparedScalarBytes":5676352,"rollingAvailableQueryCount":1476,"rollingFrameCapacity":1502,"rollingRecordBytes":108144,"slopeEvaluationsPerFit":261121,"smoothingFrameCapacity":7,"smoothingLookaheadFrames":3,"smoothingLookaheadSeconds":0.006,"smoothingRecordBytes":3150,"smoothingScalarBytes":114864,"unavailableFrameCount":0,"verificationChunkSamples":63,"verificationMaximumReportedDelaySeconds":3,"workload":{"inputChunkSamples":256,"inputDurationSeconds":6,"inputSampleCount":96000,"kind":"IntervalCPPS","name":"IntervalCPPS.float32.16000Hz.6s.h2.t10.q1.w3.pre0","profile":{"cepstrogram":{"conditioning":{"declaredInputBandwidthHz":8000,"gainPolicy":"none","method":{"interpolationDepth":50,"kind":"praat7WholeInterval"},"preEmphasisFromHz":null,"precision":"float64","ratio":{"denominator":8,"numerator":5},"requiredInputBandwidthHz":5000,"schemaVersion":1,"sourceSampleRate":16000,"targetSampleRate":10000},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"hopSeconds":0.002,"inputPrecision":"float32","preEmphasisFromHz":50,"previewHopLength":null,"schemaVersion":1},"schemaVersion":1,"settings":{"definition":"praat7002InterpolatedPower","edgePolicy":"normalizeAvailableSupport","pitchTolerance":0.05,"prominence":{"fitEndSeconds":0,"fitMethod":"praat7002Robust","fitStartSeconds":0.001,"interpolation":"parabolic","pitchCeilingHz":330,"pitchFloorHz":60,"schemaVersion":1},"quefrencyWindowSeconds":0.001,"schemaVersion":1,"subtractTrendBeforeSmoothing":false,"timeWindowSeconds":0.01}},"profileIdentity":{"identifier":{"name":"praat-7.0.02-cpps","version":1},"sha256":"7dd1ff63b7ed30c20f706567c291267194b8a592bbae515a89d7df1c9cd73bc1"},"shard":"variants","statistic":{"aggregation":"rollingFrameMean","measurement":{"cepstrogram":{"conditioning":{"declaredInputBandwidthHz":8000,"gainPolicy":"none","method":{"interpolationDepth":50,"kind":"praat7WholeInterval"},"preEmphasisFromHz":null,"precision":"float64","ratio":{"denominator":8,"numerator":5},"requiredInputBandwidthHz":5000,"schemaVersion":1,"sourceSampleRate":16000,"targetSampleRate":10000},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"hopSeconds":0.002,"inputPrecision":"float32","preEmphasisFromHz":50,"previewHopLength":null,"schemaVersion":1},"schemaVersion":1,"settings":{"definition":"praat7002InterpolatedPower","edgePolicy":"normalizeAvailableSupport","pitchTolerance":0.05,"prominence":{"fitEndSeconds":0,"fitMethod":"praat7002Robust","fitStartSeconds":0.001,"interpolation":"parabolic","pitchCeilingHz":330,"pitchFloorHz":60,"schemaVersion":1},"quefrencyWindowSeconds":0.001,"schemaVersion":1,"subtractTrendBeforeSmoothing":false,"timeWindowSeconds":0.01}},"population":"allEligible","provenances":[],"rollingWindowSeconds":3,"schemaVersion":1,"selection":{"combination":"all","rejectedTags":[],"selectionSources":[]}},"statisticIdentity":{"identifier":{"name":"cpps-allEligible-rollingFrameMean","version":1},"sha256":"5b8f8b02a0c48c6f965727eeca790d9487f4a16ee4768c6f2669894ad3239e0e"}}},{"availableFrameCount":591,"checksum":5072.180260635245,"emittedFrameCount":592,"exportedScalarCount":2122281,"fitPointCount":512,"inputSHA256":"0436923454bc86af92326075a12d4553b117e11d3ec780d38eecec5f28f55e68","maximumContributingFrameCount":296,"maximumReportedDelaySeconds":0.066,"name":"OwnedDiagnostics.float64.16000Hz.6s.h10.t10.q1.w3.pre1","preparedInputBytes":768000,"preparedScalarBytes":170280,"rollingAvailableQueryCount":591,"rollingFrameCapacity":302,"rollingRecordBytes":21744,"slopeEvaluationsPerFit":261121,"smoothingFrameCapacity":1,"smoothingLookaheadFrames":0,"smoothingLookaheadSeconds":0,"smoothingRecordBytes":450,"smoothingScalarBytes":65616,"unavailableFrameCount":1,"verificationChunkSamples":63,"verificationMaximumReportedDelaySeconds":0.05543750000000001,"workload":{"inputChunkSamples":256,"inputDurationSeconds":6,"inputSampleCount":96000,"kind":"OwnedDiagnostics","name":"OwnedDiagnostics.float64.16000Hz.6s.h10.t10.q1.w3.pre1","profile":{"cepstrogram":{"conditioning":{"declaredInputBandwidthHz":8000,"gainPolicy":"none","method":{"cutoffFraction":0.9,"kind":"streamingPreview","lobes":16},"preEmphasisFromHz":null,"precision":"float64","ratio":{"denominator":8,"numerator":5},"requiredInputBandwidthHz":5000,"schemaVersion":1,"sourceSampleRate":16000,"targetSampleRate":10000},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"hopSeconds":0.01,"inputPrecision":"float64","preEmphasisFromHz":50,"previewHopLength":100,"schemaVersion":1},"schemaVersion":1,"settings":{"definition":"praat7002InterpolatedPower","edgePolicy":"normalizeAvailableSupport","pitchTolerance":0.05,"prominence":{"fitEndSeconds":0,"fitMethod":"praat7002Robust","fitStartSeconds":0.001,"interpolation":"parabolic","pitchCeilingHz":330,"pitchFloorHz":60,"schemaVersion":1},"quefrencyWindowSeconds":0.001,"schemaVersion":1,"subtractTrendBeforeSmoothing":true,"timeWindowSeconds":0.01}},"profileIdentity":{"identifier":{"name":"finite-fir-preview-cpps","version":1},"sha256":"cf173f9ea711eea0b7e9611549598b85eb54589e0cf5cd49dfdf561c03ff21e5"},"shard":"variants","statistic":{"aggregation":"rollingFrameMean","measurement":{"cepstrogram":{"conditioning":{"declaredInputBandwidthHz":8000,"gainPolicy":"none","method":{"cutoffFraction":0.9,"kind":"streamingPreview","lobes":16},"preEmphasisFromHz":null,"precision":"float64","ratio":{"denominator":8,"numerator":5},"requiredInputBandwidthHz":5000,"schemaVersion":1,"sourceSampleRate":16000,"targetSampleRate":10000},"frame":{"definition":"praat-7.0.02-power-cepstrum","frameLength":1000,"pitchFloorHz":60,"precision":"float64","sampleRate":10000,"schemaVersion":1,"transformLength":1024},"hopSeconds":0.01,"inputPrecision":"float64","preEmphasisFromHz":50,"previewHopLength":100,"schemaVersion":1},"schemaVersion":1,"settings":{"definition":"praat7002InterpolatedPower","edgePolicy":"normalizeAvailableSupport","pitchTolerance":0.05,"prominence":{"fitEndSeconds":0,"fitMethod":"praat7002Robust","fitStartSeconds":0.001,"interpolation":"parabolic","pitchCeilingHz":330,"pitchFloorHz":60,"schemaVersion":1},"quefrencyWindowSeconds":0.001,"schemaVersion":1,"subtractTrendBeforeSmoothing":true,"timeWindowSeconds":0.01}},"population":"allEligible","provenances":[],"rollingWindowSeconds":3,"schemaVersion":1,"selection":{"combination":"all","rejectedTags":[],"selectionSources":[]}},"statisticIdentity":{"identifier":{"name":"cpps-allEligible-rollingFrameMean","version":1},"sha256":"33275506d703e00135f77d2a33007bba3ea3e0e614bbb509b65680bb9a2d5901"}}}]''')
        selected = {r['name']: benchmark.expected_cases()[r['name']] for r in examples}
        with patch.object(benchmark, 'expected_cases', return_value=selected):
            benchmark.validate_matrix(examples)
            for key in ('preparedScalarBytes', 'smoothingScalarBytes', 'preparedInputBytes',
                        'availableFrameCount', 'emittedFrameCount', 'unavailableFrameCount',
                        'exportedScalarCount', 'smoothingFrameCapacity', 'rollingFrameCapacity',
                        'smoothingLookaheadFrames', 'smoothingLookaheadSeconds',
                        'fitPointCount', 'slopeEvaluationsPerFit', 'verificationChunkSamples'):
                bad = copy.deepcopy(examples); bad[0][key] += 1
                with self.assertRaises(ValueError, msg=key): benchmark.validate_matrix(bad)
            mutations = [
                lambda r: r['workload']['profile']['settings'].update(pitchTolerance=.9),
                lambda r: r['workload']['statistic'].update(rollingWindowSeconds=5),
                lambda r: r['workload']['profileIdentity'].update(sha256='0'*64),
                lambda r: r['workload']['statisticIdentity'].update(sha256='0'*64),
                lambda r: r.update(rollingAvailableQueryCount=0),
                lambda r: r.update(maximumContributingFrameCount=10**6),
                lambda r: r.update(smoothingRecordBytes=0),
                lambda r: r.update(rollingRecordBytes=1),
                lambda r: r.update(maximumReportedDelaySeconds=float('nan')),
                lambda r: r.update(verificationMaximumReportedDelaySeconds=-1),
                lambda r: r.update(checksum=float('nan')),
                lambda r: r.update(inputSHA256='missing'),
            ]
            for mutation in mutations:
                bad = copy.deepcopy(examples); mutation(bad[0])
                with self.assertRaises(ValueError): benchmark.validate_matrix(bad)
            for bad in (examples[:-1], examples + examples[:1]):
                with self.assertRaises(ValueError): benchmark.validate_matrix(bad)
