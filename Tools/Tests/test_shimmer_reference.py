"""Independent equation anchors and malformed reference transcript controls."""
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
import shimmer_catalog
import shimmer_oracle
import shimmer_reference

_spec = importlib.util.spec_from_file_location('shimmer_fixture_verification', ROOT / 'Tools/Shimmer/verify.py')
shimmer_verify = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(shimmer_verify)


class ShimmerOracleTests(unittest.TestCase):
    def case(self, name):
        return next(c for c in shimmer_catalog.cases() if c['name'] == name)

    def evaluate(self, name):
        return shimmer_oracle.evaluate(self.case(name))

    def test_constant_minimum_counts_and_zero_are_distinct(self):
        for n in range(14):
            result = self.evaluate(f'constant-{n}')
            for key, minimum in [('local', 2), ('db', 2), ('apq3', 3), ('apq5', 5), ('apq11', 11), ('dda', 3)]:
                self.assertEqual(result['values'][key], 0. if n >= minimum else None)
            self.assertEqual(result['normalizationCount'], max(0, n - 1))

    def test_alternating_closed_form_six_variants(self):
        result = self.evaluate('alternating')
        # Thirteen amplitudes: 1, 5/4, ..., 1. Normalization mean = 9/8.
        expected = dict(local=2/9, db=20 * math.log10(1.25), apq3=4/27,
                        apq5=4/45, apq11=4/33, dda=4/9)
        for key, value in expected.items():
            self.assertAlmostEqual(result['values'][key], value, delta=2e-15)
        self.assertEqual([len(result[k]) for k in ('pairStartIndices', 'apq3WindowStartIndices',
                         'apq5WindowStartIndices', 'apq11WindowStartIndices')], [12, 11, 9, 3])

    def test_ramp_is_locally_variable_but_has_zero_centered_deviation(self):
        result = self.evaluate('linear-ramp')
        self.assertEqual(result['meanAmplitude'], 43/32)
        self.assertEqual(result['values']['local'], 2/43)
        for key in ('apq3', 'apq5', 'apq11', 'dda'):
            self.assertEqual(result['values'][key], 0.)

    def test_reference_normalization_is_explicitly_asymmetric(self):
        self.assertEqual(self.evaluate('two-ascending')['values']['local'], 1.)
        self.assertEqual(self.evaluate('two-descending')['values']['local'], .5)
        self.assertEqual(self.evaluate('two-ascending')['values']['db'],
                         self.evaluate('two-descending')['values']['db'])

    def test_rejected_pairs_do_not_filter_reference_normalization(self):
        result = self.evaluate('excluded-normalization')
        self.assertEqual(result['normalizationIndices'], [0, 1, 2, 3])
        self.assertEqual(result['meanAmplitude'], 107/4)
        self.assertEqual(result['pairStartIndices'], [0, 3])
        self.assertEqual(result['values']['local'], 10/107)
        self.assertIsNone(result['values']['apq3'])

    def test_zero_is_denominator_member_but_rejects_adjacent_numerators(self):
        result = self.evaluate('zero-normalization')
        self.assertEqual(result['zeroAmplitudeCount'], 1)
        self.assertEqual(result['pairStartIndices'], [1, 2])
        self.assertEqual(result['values']['local'], .75)
        self.assertEqual(result['values']['apq3'], .5)
        self.assertTrue(all(v is None for v in self.evaluate('all-zero')['values'].values()))

    def test_gain_and_time_invariance(self):
        for name in ('alternating', 'linear-ramp', 'sinusoidal', 'outlier'):
            baseline = self.evaluate(name)
            for suffix in ('tiny', 'quiet', 'loud', 'large', 'half-time', 'double-time'):
                result = self.evaluate(name + '-' + suffix)
                self.assertEqual(result['values'], baseline['values'])
                for key in ('pairStartIndices', 'apq3WindowStartIndices', 'apq5WindowStartIndices', 'apq11WindowStartIndices'):
                    self.assertEqual(result[key], baseline[key])

    def test_threshold_equality_inclusive_and_adjacent_rejections_split_windows(self):
        for suffix, count in [('below', 0), ('equal', 12), ('above', 12)]:
            self.assertEqual(len(self.evaluate('factor-' + suffix)['pairStartIndices']), count)
        self.assertEqual(len(self.evaluate('bounds-equal')['pairStartIndices']), 12)
        self.assertEqual(len(self.evaluate('bounds-floor-above')['pairStartIndices']), 6)
        self.assertEqual(len(self.evaluate('bounds-ceiling-below')['pairStartIndices']), 6)
        result = self.evaluate('split-runs')
        self.assertEqual(result['pairStartIndices'], list(range(5)) + list(range(6, 11)))
        self.assertEqual(result['apq5WindowStartIndices'], [0, 1, 6, 7])
        self.assertEqual(result['apq11WindowStartIndices'], [])
        self.assertEqual(self.evaluate('apq11-outer-only-failure')['apq11WindowStartIndices'], [])
        self.assertEqual(self.evaluate('apq5-outer-only-failure')['apq5WindowStartIndices'], [])

    def test_cropped_tier_uses_only_selected_records(self):
        self.assertEqual(self.evaluate('crop-exact-edges')['selectedAmplitudeIndices'], list(range(2, 11)))
        self.assertEqual(self.evaluate('crop-inside-edges')['selectedAmplitudeIndices'], list(range(3, 10)))
        self.assertEqual(self.evaluate('crop-empty')['selectedAmplitudeCount'], 0)
        self.assertEqual(self.evaluate('crop-one')['selectedAmplitudeCount'], 1)

    def test_catalog_unique_and_valid(self):
        cases = shimmer_catalog.cases()
        self.assertEqual(len(cases), len({c['name'] for c in cases}))
        for case in cases: shimmer_oracle.validate(case)

    def test_invalid_input_rejected_before_reference_execution(self):
        base = self.case('constant-2')
        patches = [{'extra': 1}, {'schemaVersion': True}, {'name': '\"\nRemove all'},
            {'timesSeconds': [0., 0.]}, {'timesSeconds': [.1, .01]}, {'timesSeconds': [False, .01]},
            {'timesSeconds': [0., math.nan]}, {'amplitudes': [1., math.inf]}, {'amplitudes': [1., -1.]},
            {'amplitudes': [True, 1.]}, {'amplitudes': [1.]}, {'amplitudes': [1e-200, 1.]},
            {'amplitudes': [1., 10 ** 1000]}, {'maximumAmplitudeFactor': 10 ** 1000},
            {'maximumAmplitudeFactor': .99}, {'minimumPeriodSeconds': 0.},
            {'maximumPeriodSeconds': .11}, {'domainEndSeconds': 61.}, {'queryEndSeconds': 0.}]
        for patch in patches:
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                shimmer_reference.script({**deepcopy(base), **patch})


class ShimmerProtocolTests(unittest.TestCase):
    def setUp(self):
        self.case = shimmer_catalog.make_case('constant', [1., 1.])
        self.raw = '\n'.join(['begin\tshimmer-reference-v1', 'count\t2',
            'amplitude\t1\t0.00390625\t1', 'amplitude\t2\t0.01171875\t1',
            'local\t0', 'db\t0', 'apq3\t--undefined--', 'apq5\t--undefined--',
            'apq11\t--undefined--', 'dda\t--undefined--', 'end\tshimmer-reference-v1', ''])

    def test_zero_and_unavailable_remain_distinct(self):
        result = shimmer_reference.parse(self.raw, self.case)
        self.assertEqual(result['local'], 0.)
        self.assertEqual(result['db'], 0.)
        self.assertIsNone(result['apq11'])

    def test_missing_extra_reordered_and_corrupted_records_fail(self):
        patches = [('begin\tshimmer-reference-v1\n', ''), ('count\t2', 'count\t3'),
            ('amplitude\t2\t', 'amplitude\t1\t'), ('0.01171875', '0.0117'),
            ('0.00390625\t1', '0.00390625\t2'), ('count\t2', 'count\t02'),
            ('local\t0', 'local\t--undefined--'), ('dda\t--undefined--', 'dda\t0'),
            ('end\tshimmer-reference-v1', 'extra\t0\nend\tshimmer-reference-v1'),
            ('local\t0\ndb\t0', 'db\t0\nlocal\t0')]
        for before, after in patches:
            with self.subTest(before=before), self.assertRaises(ValueError):
                shimmer_reference.parse(self.raw.replace(before, after), self.case)
        with self.assertRaises(ValueError): shimmer_reference.parse(self.raw.rstrip(), self.case)

    def test_invalid_numeric_syntax_rejected(self):
        for value in ('nan', 'inf', '-inf', '-1', ' 0', '0 ', '0_0', '+0', '00', '٠', '1e9999'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                shimmer_reference.parse(self.raw.replace('local\t0', 'local\t' + value), self.case)

    def test_reference_dda_relation_checked(self):
        case = shimmer_catalog.make_case('triple', [1., 1., 1.])
        raw = self.raw.replace('count\t2', 'count\t3').replace('local\t0',
            'amplitude\t3\t0.01953125\t1\nlocal\t0')
        raw = raw.replace('apq3\t--undefined--', 'apq3\t0.25').replace('dda\t--undefined--', 'dda\t0.75')
        self.assertEqual(shimmer_reference.parse(raw, case)['dda'], .75)
        with self.assertRaisesRegex(ValueError, 'DDA/APQ3'):
            shimmer_reference.parse(raw.replace('dda\t0.75', 'dda\t0.5'), case)


class ShimmerFixtureVerificationTests(unittest.TestCase):
    canonical = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Shimmer'

    def test_canonical_evidence_reconstructs_without_reference_execution(self):
        report = shimmer_verify.verify(self.canonical)
        self.assertEqual((report['cases'], report['canonicalFiles']), (94, 283))
        self.assertLess(report['maximumBudgetFraction'], 1.)

    def test_rehashed_wrong_reference_answer_fails_independent_equations(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'fixtures'
            shutil.copytree(self.canonical, target)
            path = target / 'constant-5.raw.txt'
            raw = path.read_text()
            self.assertIn('local\t0\n', raw)
            path.write_text(raw.replace('local\t0\n', 'local\t0.5\n'))
            self.rehash(target, path)
            with self.assertRaisesRegex(ValueError, 'local error'):
                shimmer_verify.verify(target)

    def rehash(self, directory, path):
        manifest_path = directory / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['files'][path.name] = shimmer_reference.digest(path.read_bytes())
        manifest_path.write_bytes(shimmer_reference.canonical(manifest))

    def test_normalization_and_neighborhood_membership_cannot_be_forged(self):
        for key in ('normalizationIndices', 'pairStartIndices', 'apq11WindowStartIndices'):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / 'fixtures'
                shutil.copytree(self.canonical, target)
                path = target / 'split-runs.json'
                payload = json.loads(path.read_text())
                payload['oracle'][key].append(5)
                payload['fixtureIdentity'] = shimmer_reference.digest(shimmer_reference.canonical(
                    {k: v for k, v in payload.items() if k != 'fixtureIdentity'}))
                path.write_bytes(shimmer_reference.canonical(payload))
                self.rehash(target, path)
                with self.assertRaisesRegex(ValueError, 'cannot be independently reconstructed'):
                    shimmer_verify.verify(target)

    def test_extra_missing_and_symlink_artifacts_rejected(self):
        for mutation in ('extra', 'missing', 'symlink'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / 'fixtures'
                shutil.copytree(self.canonical, target)
                path = target / 'constant-5.raw.txt'
                if mutation == 'extra': (target / 'unexpected.json').write_text('{}')
                else:
                    path.unlink()
                    if mutation == 'symlink': path.symlink_to(self.canonical / path.name)
                with self.assertRaises(ValueError): shimmer_verify.verify(target)


if __name__ == '__main__': unittest.main()
