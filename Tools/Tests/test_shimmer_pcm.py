"""Separate PCM extraction anchors, source identity and transcript corruption checks."""
from copy import deepcopy
import importlib.util
import json
import math
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(1, str(ROOT / 'Tools/Shimmer'))
import pcm_catalog
import pcm_oracle
import pcm_reference
import native_oracle
from shimmer_reference import canonical, digest

_spec = importlib.util.spec_from_file_location('shimmer_pcm_fixture_verifier', ROOT / 'Tools/Shimmer/verify_pcm.py')
verify_pcm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verify_pcm)

CANONICAL = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/ShimmerPCM'


class ShimmerNativeOracleTests(unittest.TestCase):
    def records(self, amplitudes):
        return [dict(timeSeconds=i/128, amplitude=a, sequenceIndex=i, runID=0, rejections={'rawValue': 0})
                for i, a in enumerate(amplitudes)]

    def evaluate(self, records):
        return native_oracle.evaluate(records, dict(startSeconds=0., endSeconds=.125),
            dict(minimumPeriodSeconds=.0001, maximumPeriodSeconds=.02, maximumAmplitudeFactor=2.))

    def test_closed_form_alternation_and_masked_window_counts(self):
        records = self.records([1., 1.25] * 6 + [1.])
        result = self.evaluate(records)
        expected = dict(local=2/9, db=20 * math.log10(1.25), apq3=4/27, apq5=4/45, apq11=4/33, dda=4/9)
        for key, value in expected.items(): self.assertAlmostEqual(result['values'][key], value, delta=2e-15)
        records[6]['rejections']['rawValue'] = 1
        result = self.evaluate(records)
        self.assertEqual(result['coverage']['normalizationAmplitudeCount'], 11)
        self.assertEqual(result['coverage']['rejections']['excluded'], 1)
        self.assertEqual([len(result['windows'][str(w)]) for w in (2, 3, 5, 11)], [10, 8, 4, 0])

    def test_zero_denominator_membership_and_gap_identity_are_independent(self):
        result = self.evaluate(self.records([0., 1., 1., 2.]))
        self.assertEqual(result['values']['local'], .75)
        self.assertEqual(result['values']['apq3'], .5)
        self.assertEqual(result['coverage']['meanAmplitude'], 2/3)
        records = self.records([1.] * 13)
        for record in records[6:]: record['sequenceIndex'] += 1
        result = self.evaluate(records)
        self.assertEqual(result['coverage']['normalizationAmplitudeCount'], 12)
        self.assertEqual([len(result['windows'][str(w)]) for w in (2, 3, 5, 11)], [11, 9, 5, 0])
        self.assertEqual(result['coverage']['rejections']['discontinuousPairs'], 1)

    def test_malformed_native_records_rejected(self):
        for patch in ({'unknown': 1}, {'amplitude': None}, {'amplitude': math.nan},
                      {'sequenceIndex': True}, {'runID': -1}, {'timeSeconds': math.inf},
                      {'rejections': {'rawValue': 256}}, {'rejections': []}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                records = self.records([1., 1.])
                records[0].update(patch)
                self.evaluate(records)
        records = self.records([1., 1.])
        records[1]['timeSeconds'] = records[0]['timeSeconds']
        with self.assertRaises(ValueError): self.evaluate(records)


class ShimmerPCMOracleTests(unittest.TestCase):
    def anchor(self, samples):
        case = dict(sampleRate=1000, queryStartSeconds=0., queryEndSeconds=.1,
                    minimumPeriodSeconds=.001, maximumPeriodSeconds=.02, maximumAdjacentPeriodFactor=1.3)
        source = dict(samples=samples, fixture={'reference': {'data': {'pulseTimesSeconds': [.0235, .0335, .0435]}}})
        return case, source

    def test_constant_and_impulse_have_independent_closed_form_rms(self):
        case, source = self.anchor([.25] * 100)
        result = pcm_oracle.amplitudes(case, source)
        self.assertEqual(len(result), 1)
        self.assertAlmostEqual(result[0]['rmsAmplitude'], .25, delta=1e-15)
        impulse = [0.] * 100
        impulse[33] = 1.
        for gain in (1., -1., .1, 1e-200):
            case, source = self.anchor([s * gain for s in impulse])
            actual = pcm_oracle.amplitudes(case, source)[0]['rmsAmplitude']
            self.assertAlmostEqual(actual / abs(gain), math.sqrt(2/3), delta=1e-14)

    def test_cropped_edges_missing_energy_and_bad_neighbor_periods_are_unavailable(self):
        case, source = self.anchor([.25] * 100)
        self.assertEqual(pcm_oracle.amplitudes({**case, 'queryStartSeconds': .0335}, source), [])
        self.assertEqual(pcm_oracle.amplitudes({**case, 'maximumPeriodSeconds': .009}, source), [])
        source['samples'] = [0.] * 100
        self.assertEqual(pcm_oracle.amplitudes(case, source), [])

    def test_catalog_rejects_changed_unknown_and_unsafe_inputs(self):
        cases = pcm_catalog.cases()
        self.assertEqual(len(cases), 80)
        self.assertEqual(len({c['name'] for c in cases}), 80)
        for case in cases: pcm_catalog.validate(case)
        for patch in ({'extra': 1}, {'schemaVersion': True}, {'schemaVersion': 1.0},
                      {'sampleRate': True}, {'pulseFixture': '../../unapproved'},
                      {'queryEndSeconds': math.nan}, {'maximumAmplitudeFactor': 0.}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                pcm_catalog.validate({**deepcopy(cases[0]), **patch})


class ShimmerPCMProtocolTests(unittest.TestCase):
    def setUp(self):
        self.case = next(c for c in pcm_catalog.cases() if c['name'] == 'gaussian-16000-150-float64-full')
        self.source = pcm_catalog.source(self.case)
        self.raw = (CANONICAL / (self.case['name'] + '.raw.txt')).read_text()

    def test_pulse_identity_and_separate_query_routes_are_preserved(self):
        data = pcm_reference.parse(self.raw, self.case, self.source)
        self.assertEqual(data['pulseCount'], self.source['fixture']['reference']['data']['pulseCount'])
        self.assertEqual(data['tierValues'], data['soundValues'])
        self.assertEqual(data['amplitudeState'], 'complete')
        self.assertGreater(len(data['amplitudes']), 50)

    def test_protocol_rejects_missing_reordered_or_changed_records(self):
        lines = self.raw.splitlines()
        first_amplitude = next(s for s in lines if s.startswith('amplitude\t1\t'))
        pulse = next(s for s in lines if s.startswith('pulse\t2\t'))
        replacements = [('begin\tshimmer-pcm-v1\n', ''), ('input\t16000\t8000', 'input\t16000\t7999'),
            (pulse, pulse.replace('pulse\t2\t', 'pulse\t1\t')),
            (first_amplitude, first_amplitude.rsplit('\t', 1)[0] + '\t0'),
            ('tier-local\t', 'tier-db\t'), ('end\tshimmer-pcm-v1', 'extra\t1\nend\tshimmer-pcm-v1')]
        for before, after in replacements:
            self.assertIn(before, self.raw)
            with self.subTest(before=before), self.assertRaises(ValueError):
                pcm_reference.parse(self.raw.replace(before, after), self.case, self.source)

    def test_combined_tier_disagreement_and_nonfinite_numbers_rejected(self):
        line = next(s for s in self.raw.splitlines() if s.startswith('sound-local\t'))
        for value in ('0.5', 'nan', 'inf', '-1', '00', '+1', ' 0', '--undefined--'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                pcm_reference.parse(self.raw.replace(line, 'sound-local\t' + value), self.case, self.source)

    def test_skipped_queries_are_not_fabricated_reference_answers(self):
        case = next(c for c in pcm_catalog.cases() if c['name'] == 'silence-float64-full')
        source = pcm_catalog.source(case)
        raw = (CANONICAL / (case['name'] + '.raw.txt')).read_text()
        data = pcm_reference.parse(raw, case, source)
        self.assertEqual(data['amplitudeState'], 'insufficientPulses')
        self.assertIsNone(data['tierValues'])
        self.assertIsNone(data['soundValues'])
        with self.assertRaises(ValueError):
            pcm_reference.parse(raw.replace('skippedInsufficientPulses', 'complete'), case, source)


class ShimmerPCMFixtureTests(unittest.TestCase):
    def rehash(self, directory, path):
        manifest_path = directory / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['files'][path.name] = digest(path.read_bytes())
        manifest_path.write_bytes(canonical(manifest))

    def test_all_pcm_evidence_reconstructs_without_reference_execution(self):
        report = verify_pcm.verify(CANONICAL)
        self.assertEqual((report['cases'], report['canonicalFiles']), (80, 161))
        self.assertGreater(report['executedQueries'], 60)
        self.assertGreater(report['skippedInsufficientPulses'], 0)

    def test_rehashed_matching_wrong_statistics_still_fail_independent_equations(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'fixtures'
            shutil.copytree(CANONICAL, target)
            path = target / 'gaussian-16000-150-float64-full.raw.txt'
            lines = path.read_text().splitlines()
            for i, line in enumerate(lines):
                if line.startswith(('tier-local\t', 'sound-local\t')):
                    lines[i] = line.split('\t')[0] + '\t0.5'
            path.write_text('\n'.join(lines) + '\n')
            self.rehash(target, path)
            with self.assertRaisesRegex(ValueError, 'local error'):
                verify_pcm.verify(target)

    def test_rehashed_wrong_amplitude_fails_extraction_before_formula_comparison(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'fixtures'
            shutil.copytree(CANONICAL, target)
            path = target / 'gaussian-16000-150-float64-full.raw.txt'
            lines = path.read_text().splitlines()
            i = next(i for i, line in enumerate(lines) if line.startswith('amplitude\t1\t'))
            lines[i] = lines[i].rsplit('\t', 1)[0] + '\t0.8'
            path.write_text('\n'.join(lines) + '\n')
            self.rehash(target, path)
            with self.assertRaisesRegex(ValueError, 'cropped RMS differs'):
                verify_pcm.verify(target)


if __name__ == '__main__': unittest.main()
