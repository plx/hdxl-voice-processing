"""Independent YIN equation anchors, selection and denominator checks."""
import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('yin_test_oracle', ROOT / 'Tools/YIN/oracle.py')
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)


class YINOracleTests(unittest.TestCase):
    def test_closed_form_period_four_difference_and_cmnd(self):
        profile = oracle.configuration(rate=4000, floor=500, ceiling=1000, hop=4)
        row = oracle.frame(([1., 0., -1., 0.] * 5)[:17], profile)
        self.assertEqual(row['difference'], [0., 8., 16., 8., 0., 8., 16., 8., 0., 8.])
        for a, b in zip(row['cmnd'], [1., 1., 4/3, .75, 0., 1., 12/7, .875, 0., 1.]):
            self.assertAlmostEqual(a, b, places=15)
        self.assertEqual([x['integerLag'] for x in row['candidates']], [4, 8])
        self.assertEqual(row['selectedCandidateIndex'], 0)
        self.assertEqual(row['candidates'][0]['frequencyHz'], 1000.)
        self.assertEqual(row['status'], 'voiced')

    def test_parabola_vertex_and_nonminimum(self):
        self.assertEqual(oracle.vertex(2.25, .25, .25), (.5, 0.))
        self.assertEqual(oracle.vertex(1., 2., 1.), (0., 2.))
        self.assertEqual(oracle.vertex(1., 1., 1.), (0., 1.))

    def test_boundary_canonicalization_is_narrow_and_preserves_out_of_range(self):
        tolerance = oracle.configuration()['rangeBoundaryToleranceSamples']
        for delta in (-1e-6, 0., 1e-6):
            self.assertEqual(oracle.canonical_period(320 + delta, 20., 320., tolerance), 320.)
            self.assertEqual(oracle.canonical_period(20 + delta, 20., 320., tolerance), 20.)
        for period in (19.99999, 20.00001, 319.99999, 320.00001):
            self.assertEqual(oracle.canonical_period(period, 20., 320., tolerance), period)

    def test_full_lag_support_and_partial_tail(self):
        profile = oracle.configuration(rate=4000, floor=500, ceiling=1000, hop=4)
        self.assertEqual(oracle.geometry(profile)[-1], 17)
        rows = oracle.stream([0.] * 24, profile)
        self.assertEqual([x['startSample'] for x in rows], [0, 4, 8])
        self.assertEqual([x['observedSampleCount'] for x in rows], [17, 17, 16])
        self.assertEqual(rows[-1]['reason'], 'insufficientData')
        self.assertEqual(oracle.stream([], profile), [])

    def test_constant_is_not_a_perfect_period_and_silence_is_not_zero_hz(self):
        profile = oracle.configuration(rate=4000, floor=500, ceiling=1000, hop=4)
        for value, reason in ((0., 'silence'), (.25, 'lowConfidence')):
            row = oracle.frame([value] * 17, profile)
            self.assertEqual(row['cmnd'], [1.] * 10)
            self.assertIsNone(row['selectedCandidateIndex'])
            self.assertEqual(row['status'], 'unvoiced')
            self.assertEqual(row['reason'], reason)

    def test_invalid_and_unsupported_profiles_or_frames_fail(self):
        invalid = [dict(rate=True), dict(rate=3999), dict(floor=10), dict(ceiling=5000),
                   dict(floor=60, ceiling=60.1), dict(hop=0), dict(integration=10),
                   dict(silence=-1), dict(threshold=float('nan')), dict(precision='half')]
        for changes in invalid:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                oracle.configuration(**changes)
        profile = oracle.configuration()
        for samples in ([float('nan')], [float('inf')], [0.] * 642):
            with self.assertRaises(ValueError): oracle.frame(samples, profile)
        malformed = {**profile, 'unknown': True}
        with self.assertRaises(ValueError): oracle.geometry(malformed)

    def test_tracker_retains_raw_choice_and_resets_on_uncertainty(self):
        def candidate(hz, error, lag):
            return {'frequencyHz': hz, 'normalizedError': error,
                    'integerLag': lag, 'isThresholdQualified': True}
        low = candidate(100., .02, 160)
        high = candidate(200., .01, 80)
        frames = [
            {'startSample': 0, 'observedSampleCount': 321, 'status': 'voiced',
             'selectedCandidateIndex': 0, 'candidates': [low]},
            {'startSample': 80, 'observedSampleCount': 321, 'status': 'voiced',
             'selectedCandidateIndex': 0, 'candidates': [high, low]},
            {'startSample': 160, 'observedSampleCount': 321, 'status': 'uncertain',
             'selectedCandidateIndex': 0, 'candidates': [high]},
            {'startSample': 240, 'observedSampleCount': 321, 'status': 'voiced',
             'selectedCandidateIndex': 0, 'candidates': [high, low]},
        ]
        original = copy.deepcopy(frames)
        tracked = oracle.track(frames)
        self.assertEqual([x['selectedCandidateIndex'] for x in tracked], [0, 1, 0, 0])
        self.assertEqual([x['dependencyStartSample'] for x in tracked], [0, 0, 160, 240])
        self.assertEqual([x['dependencySampleCount'] for x in tracked], [321, 401, 321, 321])
        self.assertEqual([x['changedSelection'] for x in tracked], [False, True, False, False])
        self.assertEqual(frames, original)

    def isolated(self, code):
        prefix = "import sys;sys.path.insert(0,'Tools/YIN');import oracle,reference,catalog,verify;"
        return subprocess.run([sys.executable, '-c', prefix + code], cwd=ROOT,
                              capture_output=True, text=True, timeout=120)

    def test_metric_denominators_retain_uncertain_and_partial_frames(self):
        code = """
case={'source':{'kind':'tone','frequencyHz':100.},'profile':{'sampleRate':16000}}
rows=[{'observedSampleCount':320,'requiredSampleCount':320,'startSample':0,
       'reason':None,'status':'uncertain','selectedCandidateIndex':0,
       'candidates':[{'frequencyHz':200.}]},
      {'observedSampleCount':40,'requiredSampleCount':320,'startSample':160,
       'reason':'insufficientData','status':'unavailable','selectedCandidateIndex':None,'candidates':[]}]
m=reference.metrics(case,rows)
assert m['potentialFrameCount']==2 and m['fullSupportFrameCount']==1
assert m['availableCoverageIncludingPartial']==.5 and m['voicedCoverageOfFullSupport']==0
assert m['knownTargetFullSupportCount']==1 and m['knownTargetAvailableCount']==1
assert m['availableGrossErrorCount']==m['availableOctaveErrorCount']==1
assert m['fineErrorCount']==0 and m['meanFineAbsoluteCents'] is None
assert m['unavailableReasons']=={'insufficientData':1}
"""
        result = self.isolated(code)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rehashed_oracle_corruption_cannot_become_a_golden(self):
        code = """
case=catalog.cases()[0]
record,_=reference.evaluate(case)
verify.verify_record(record,case)
record['frames'][0]['difference'][10]+=.1
try: verify.verify_record(record,case)
except ValueError as e: assert 'Independent YIN oracle' in str(e)
else: raise AssertionError('Corrupt difference accepted')
"""
        result = self.isolated(code)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_complete_independent_catalog(self):
        directory = os.environ.get('HDXL_YIN_REFERENCE_DIRECTORY',
            str(ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/YIN'))
        result = self.isolated(f"from pathlib import Path;assert verify.verify(Path({directory!r})) == 54")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__': unittest.main()
