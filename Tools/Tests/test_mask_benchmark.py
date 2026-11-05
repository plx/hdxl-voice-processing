"""Guard Mask evidence coverage and allocation exemptions."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('mask_benchmark', ROOT / 'Tools/Masks/benchmark.py')
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
KINDS = ('LTSF','Energy','Routing','Resolution','Metadata','ResetLTSF','ResetEnergy','ResetRouting')
MATRIX = [{'name': k, 'workload': {'kind': k}} for k in KINDS]


def capture(mode):
    names = [f'Mask.{op}.{k}' for k in KINDS for op in benchmark.OPERATIONS]
    if mode == 'allocation':
        names += [benchmark.CONTROL]
    metrics = ['wallClock', 'cpuTotal'] if mode == 'timing' else ['wallClock', *benchmark.DIAGNOSTICS]
    rows = []
    for name in names:
        values = []
        allocating = name == benchmark.CONTROL or '.Prepare.' in name or name.endswith(('Resolution','Metadata'))
        for metric in metrics:
            maximum = 1 if allocating or metric in ('wallClock', 'cpuTotal') else 0
            values.append({'metric': {metric: {}}, 'scalingFactor': 1,
                           'statistics': {'histogram': {'_totalCount': 10, 'maxValue': maximum, 'counts': [10]}}})
        rows += [{'name': name, 'target': 'MaskBenchmarks'}, values]
    return {'results': rows}


class MaskBenchmarkTests(unittest.TestCase):
    def test_positive_control_requires_every_counter(self):
        good = capture('allocation')
        self.assertEqual(len(benchmark.validate_raw(good, MATRIX, 'allocation')), 17)
        for metric in benchmark.DIAGNOSTICS:
            bad = copy.deepcopy(good)
            for value in bad['results'][-1]:
                if metric in value['metric']:
                    value['statistics']['histogram']['maxValue'] = 0
            with self.assertRaisesRegex(ValueError, 'Unavailable'):
                benchmark.validate_raw(bad, MATRIX, 'allocation')

    def test_only_explicit_owned_exports_may_allocate(self):
        for i, kind in enumerate(KINDS):
            if kind in ('Resolution','Metadata'):
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
        self.assertEqual(len(all_cases), 26)
        groups = [set(benchmark.expected_cases(shard)) for shard in benchmark.SHARDS]
        self.assertEqual([len(g) for g in groups], [3, 4, 19])
        self.assertEqual(set.union(*groups), set(all_cases))
        self.assertEqual(sum(map(len, groups)), 26)
        self.assertEqual({row[3] for row in all_cases.values()}, {64,256,1024})
        self.assertEqual({row[2] for row in all_cases.values()}, {16000,48000})
        with self.assertRaisesRegex(ValueError, 'Unknown'): benchmark.expected_cases('float16')

    def test_corrupt_profiles_timeline_counts_storage_and_receipts_fail(self):
        # A captured ten-minute metadata record, not numerical output golden values.
        examples = json.loads(r'''[{"checksum":-7142053.677067985,"coverage":{"eligibleCoverage":0.5,"eligibleDurationSeconds":594.04,"eligibleSampleCount":9504640,"excludedEligibleDurationSeconds":297.02,"excludedEligibleSampleCount":4752320,"missingDurationSeconds":5.96,"missingSampleCount":95360,"selectedDurationSeconds":297.02,"selectedSampleCount":4752320,"sourceCoverage":0.4950333333333333,"sourceDurationSeconds":600,"sourceSampleCount":9600000,"tags":[{"durationSeconds":5.96,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":95360,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"missingAcquisition"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"silence"},{"durationSeconds":198,"eligibleDurationSeconds":198,"eligibleSampleCount":3168000,"sampleCount":3168000,"selectedDurationSeconds":99,"selectedSampleCount":1584000,"tag":"suspectedExternalNoise"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"clipping"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"speechDetected"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"nonSpeechDetected"},{"durationSeconds":198,"eligibleDurationSeconds":198,"eligibleSampleCount":3168000,"sampleCount":3168000,"selectedDurationSeconds":99,"selectedSampleCount":1584000,"tag":"lowPeriodicityConfidence"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"algorithmInsufficiency"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"energyEligible"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"energyIneligible"}]},"emittedUnits":59999,"energyIdentity":{"identifier":{"name":"absolute-rms-eligibility-confirmed-windows","version":1},"sha256":"3b54b75039320e163a697db09933affb0586b085cbada0be8a2e927d065d1d50"},"exportedBytes":0,"inputSHA256":"d3e71e6727f22d32f817452678d5a2b8ff517eb685c242b3abd5e22aff93ffdc","layout":{"configuration":{"declaredInputBandwidthHz":8000,"flatnessThreshold":-10,"hopSeconds":0.01,"inputPrecision":"float64","longWindowSeconds":0.3,"maximumFrequencyHz":6000,"minimumFrequencyHz":70,"minimumNonSpeechSeconds":0.1,"minimumSpeechSeconds":0.1,"relativeIntensityThresholdDB":-35,"sampleRate":16000,"schemaVersion":1,"shortWindowSeconds":0.1},"firstCenterSeconds":0.00999999999999715,"frameCount":59999,"maximumEffectiveDelaySeconds":600,"source":{"epoch":{"sequence":0,"streamID":"00000000-0000-0000-0000-000000000034"},"sampleCount":9600000,"sampleRate":16000,"startSample":0},"spectral":{"effectiveMaximumFrequencyHz":5984.375,"effectiveMinimumFrequencyHz":46.875,"fftBinsPerSpectrogramBin":1,"fftLength":1024,"firstFlatnessBin":3,"firstFrequencyHz":0,"frameLength":318,"frequencyBinCount":384,"frequencyStepHz":15.625,"lastFlatnessBin":383,"longFrameCount":30,"physicalWindowSeconds":0.02,"shortAveragingEnabled":true,"spectralRingFrameCount":13}},"ltsfIdentity":{"identifier":{"name":"praat-7.0.02-ltsf-supported-domain","version":1},"sha256":"b7b394ecdf2b18bec75990d496307697df6fd4b18df7bbf23a106195f4cf0e5d"},"name":"LTSF.float64.16000Hz.600s.256chunk","observations":30000,"planSHA256":"f38d85a4c3b27e34e50a048be4fedaf01ca882e7075e793b6312491572d076af","preparedInputBytes":76800000,"preparedScalarWorkspaceBytes":6991928,"workload":{"chunkSamples":256,"energy":{"activationConfirmationWindows":2,"activationDBFS":-40,"deactivationConfirmationWindows":3,"deactivationDBFS":-45,"declaredInputBandwidthHz":8000,"inputPrecision":"float64","sampleRate":16000,"schemaVersion":1,"windowSamples":160},"inputDurationSeconds":600,"kind":"LTSF","ltsf":{"declaredInputBandwidthHz":8000,"flatnessThreshold":-10,"hopSeconds":0.01,"inputPrecision":"float64","longWindowSeconds":0.3,"maximumFrequencyHz":6000,"minimumFrequencyHz":70,"minimumNonSpeechSeconds":0.1,"minimumSpeechSeconds":0.1,"relativeIntensityThresholdDB":-35,"sampleRate":16000,"schemaVersion":1,"shortWindowSeconds":0.1},"name":"LTSF.float64.16000Hz.600s.256chunk","precision":"float64","sampleRate":16000}},{"checksum":59999,"coverage":{"eligibleCoverage":0.5,"eligibleDurationSeconds":594.04,"eligibleSampleCount":9504640,"excludedEligibleDurationSeconds":297.02,"excludedEligibleSampleCount":4752320,"missingDurationSeconds":5.96,"missingSampleCount":95360,"selectedDurationSeconds":297.02,"selectedSampleCount":4752320,"sourceCoverage":0.4950333333333333,"sourceDurationSeconds":600,"sourceSampleCount":9600000,"tags":[{"durationSeconds":5.96,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":95360,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"missingAcquisition"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"silence"},{"durationSeconds":198,"eligibleDurationSeconds":198,"eligibleSampleCount":3168000,"sampleCount":3168000,"selectedDurationSeconds":99,"selectedSampleCount":1584000,"tag":"suspectedExternalNoise"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"clipping"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"speechDetected"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"nonSpeechDetected"},{"durationSeconds":198,"eligibleDurationSeconds":198,"eligibleSampleCount":3168000,"sampleCount":3168000,"selectedDurationSeconds":99,"selectedSampleCount":1584000,"tag":"lowPeriodicityConfidence"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"algorithmInsufficiency"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"energyEligible"},{"durationSeconds":0,"eligibleDurationSeconds":0,"eligibleSampleCount":0,"sampleCount":0,"selectedDurationSeconds":0,"selectedSampleCount":0,"tag":"energyIneligible"}]},"emittedUnits":1,"energyIdentity":{"identifier":{"name":"absolute-rms-eligibility-confirmed-windows","version":1},"sha256":"3b54b75039320e163a697db09933affb0586b085cbada0be8a2e927d065d1d50"},"exportedBytes":0,"inputSHA256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","layout":{"configuration":{"declaredInputBandwidthHz":8000,"flatnessThreshold":-10,"hopSeconds":0.01,"inputPrecision":"float64","longWindowSeconds":0.3,"maximumFrequencyHz":6000,"minimumFrequencyHz":70,"minimumNonSpeechSeconds":0.1,"minimumSpeechSeconds":0.1,"relativeIntensityThresholdDB":-35,"sampleRate":16000,"schemaVersion":1,"shortWindowSeconds":0.1},"firstCenterSeconds":0.00999999999999715,"frameCount":59999,"maximumEffectiveDelaySeconds":600,"source":{"epoch":{"sequence":0,"streamID":"00000000-0000-0000-0000-000000000034"},"sampleCount":9600000,"sampleRate":16000,"startSample":0},"spectral":{"effectiveMaximumFrequencyHz":5984.375,"effectiveMinimumFrequencyHz":46.875,"fftBinsPerSpectrogramBin":1,"fftLength":1024,"firstFlatnessBin":3,"firstFrequencyHz":0,"frameLength":318,"frequencyBinCount":384,"frequencyStepHz":15.625,"lastFlatnessBin":383,"longFrameCount":30,"physicalWindowSeconds":0.02,"shortAveragingEnabled":true,"spectralRingFrameCount":13}},"ltsfIdentity":{"identifier":{"name":"praat-7.0.02-ltsf-supported-domain","version":1},"sha256":"b7b394ecdf2b18bec75990d496307697df6fd4b18df7bbf23a106195f4cf0e5d"},"name":"ResetLTSF.float64.16000Hz.600s.256chunk","observations":30000,"planSHA256":"f38d85a4c3b27e34e50a048be4fedaf01ca882e7075e793b6312491572d076af","preparedInputBytes":0,"preparedScalarWorkspaceBytes":6991928,"workload":{"chunkSamples":256,"energy":{"activationConfirmationWindows":2,"activationDBFS":-40,"deactivationConfirmationWindows":3,"deactivationDBFS":-45,"declaredInputBandwidthHz":8000,"inputPrecision":"float64","sampleRate":16000,"schemaVersion":1,"windowSamples":160},"inputDurationSeconds":600,"kind":"ResetLTSF","ltsf":{"declaredInputBandwidthHz":8000,"flatnessThreshold":-10,"hopSeconds":0.01,"inputPrecision":"float64","longWindowSeconds":0.3,"maximumFrequencyHz":6000,"minimumFrequencyHz":70,"minimumNonSpeechSeconds":0.1,"minimumSpeechSeconds":0.1,"relativeIntensityThresholdDB":-35,"sampleRate":16000,"schemaVersion":1,"shortWindowSeconds":0.1},"name":"ResetLTSF.float64.16000Hz.600s.256chunk","precision":"float64","sampleRate":16000}}]''')
        expected = {r['name']: benchmark.expected_cases()[r['name']] for r in examples}
        with patch.object(benchmark, 'expected_cases', return_value=expected):
            benchmark.validate_matrix(examples)
            changes = [lambda r: r.pop(), lambda r: r.append(r[0]),
                lambda r: r[0]['workload'].__setitem__('chunkSamples', 65),
                lambda r: r[0]['workload']['ltsf'].__setitem__('longWindowSeconds', .2),
                lambda r: r[0]['layout']['spectral'].__setitem__('fftLength', 512),
                lambda r: r[0]['layout']['source'].__setitem__('startSample', 1),
                lambda r: r[0]['layout'].__setitem__('maximumEffectiveDelaySeconds', 0),
                lambda r: r[0].__setitem__('observations', 29999),
                lambda r: r[0].__setitem__('preparedScalarWorkspaceBytes', 0),
                lambda r: r[0].__setitem__('preparedInputBytes', 0),
                lambda r: r[0].__setitem__('emittedUnits', 0),
                lambda r: r[0].__setitem__('exportedBytes', 1),
                lambda r: r[0].__setitem__('inputSHA256', 'x'*64),
                lambda r: r[0].__setitem__('planSHA256', ''),
                lambda r: r[0]['ltsfIdentity']['identifier'].__setitem__('version', 2),
                lambda r: r[0]['coverage'].__setitem__('sourceCoverage', 1),
                lambda r: r[0]['coverage']['tags'][0].__setitem__('selectedSampleCount', 1),
                lambda r: r[0].__setitem__('checksum', float('nan'))]
            for change in changes:
                bad = copy.deepcopy(examples); change(bad)
                with self.assertRaises(ValueError): benchmark.validate_matrix(bad)
