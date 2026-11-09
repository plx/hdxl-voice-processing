"""Analytic equation anchors and protocol corruption controls, without Praat execution."""
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
sys.path.insert(1, str(ROOT / 'Tools/Jitter'))
import jitter_catalog
import jitter_oracle
import jitter_reference

_spec = importlib.util.spec_from_file_location('jitter_fixture_verification', ROOT / 'Tools/Jitter/verify.py')
jitter_verify = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(jitter_verify)


class JitterOracleTests(unittest.TestCase):
    def case(self, name):
        return next(c for c in jitter_catalog.cases() if c['name'] == name)

    def evaluate(self, name):
        return jitter_oracle.evaluate(self.case(name))

    def test_constant_requires_each_neighborhood_minimum(self):
        for n in range(8):
            result = self.evaluate(f'constant-{n}')
            for key, needed in [('absolute', 2), ('local', 2), ('rap', 3), ('ddp', 3), ('ppq5', 5)]:
                self.assertEqual(result['values'][key], 0. if n >= needed else None)
            self.assertEqual(result['meanPeriodCount'], n)

    def test_alternating_closed_form_five_variants(self):
        result = self.evaluate('alternating')
        # Twelve periods alternate 2/256, 2.25/256; mean 2.125/256.
        expected = {'absolute': 1/1024, 'local': 2/17, 'rap': 4/51, 'ppq5': 4/85, 'ddp': 4/17}
        for key, value in expected.items(): self.assertEqual(result['values'][key], value)
        self.assertEqual((len(result['pairIndices']), len(result['rapWindowStartIndices']), len(result['ppq5WindowStartIndices'])), (11, 10, 8))

    def test_linear_ramp_has_nonzero_local_and_zero_centered_perturbations(self):
        result = self.evaluate('linear-ramp')
        self.assertEqual(result['values']['absolute'], 1/2048)
        self.assertEqual(result['values']['local'], 2/43)
        for key in ('rap', 'ppq5', 'ddp'): self.assertEqual(result['values'][key], 0.)

    def test_relative_scaling_and_absolute_time_scaling(self):
        for name in ('alternating', 'linear-ramp', 'outlier'):
            base = self.evaluate(name)['values']
            for suffix, scale in [('-half-time', .5), ('-double-time', 2.)]:
                values = self.evaluate(name + suffix)['values']
                for key in base:
                    self.assertEqual(values[key], base[key] * (scale if key == 'absolute' else 1))

    def test_mean_period_keeps_isolated_object_endpoints(self):
        result = self.evaluate('leading-isolated')
        self.assertEqual(result['meanPeriodIndices'], [0, 1, 2])
        self.assertEqual(result['pairIndices'], [1])
        self.assertEqual(result['values']['local'], 3/41)
        self.assertEqual(self.evaluate('interior-isolated')['meanPeriodIndices'], [0, 1, 3, 4])

    def test_cropped_mean_uses_neighbors_outside_query(self):
        result = self.evaluate('crop-isolated-center')
        self.assertEqual(result['selectedPeriodCount'], 1)
        self.assertEqual(result['boundedPeriodCount'], 1)
        self.assertEqual(result['meanPeriodCount'], 0)
        self.assertEqual(self.evaluate('crop-isolated-first')['meanPeriodIndices'], [2, 3])
        self.assertEqual(self.evaluate('crop-isolated-last')['meanPeriodIndices'], [0, 1])

    def test_invalid_neighbor_still_affects_mean_ratio_rule(self):
        self.assertEqual(self.evaluate('invalid-neighbors-similar')['meanPeriodIndices'], [1])
        self.assertEqual(self.evaluate('invalid-neighbors-distant')['meanPeriodIndices'], [])

    def test_bounds_and_factor_equality_are_inclusive(self):
        self.assertEqual(len(self.evaluate('factor-equal')['pairIndices']), 4)
        self.assertEqual(len(self.evaluate('factor-below')['pairIndices']), 0)
        self.assertEqual(len(self.evaluate('factor-above')['pairIndices']), 4)
        self.assertEqual(self.evaluate('bounds-equal')['meanPeriodCount'], 5)
        self.assertEqual(self.evaluate('bounds-floor-above')['meanPeriodIndices'], [1, 3])
        self.assertEqual(self.evaluate('bounds-ceiling-below')['meanPeriodIndices'], [0, 2, 4])

    def test_rejected_periods_never_stitch_neighbors(self):
        result = self.evaluate('split-runs')
        self.assertEqual(result['pairIndices'], [0, 1, 4, 5])
        self.assertEqual(result['rapWindowStartIndices'], [0, 4])
        self.assertEqual(result['ppq5WindowStartIndices'], [])
        self.assertEqual(self.evaluate('ppq5-outer-only-failure')['ppq5WindowStartIndices'], [])

    def test_catalog_inputs_valid_and_names_unique(self):
        cases = jitter_catalog.cases()
        self.assertEqual(len(cases), len({c['name'] for c in cases}))
        for case in cases: jitter_oracle.validate(case)

    def test_invalid_inputs_rejected_before_reference_execution(self):
        base = self.case('constant-5')
        patches = [{'extra': 1}, {'schemaVersion': True}, {'name': '"\nRemove all'},
                   {'pointsSeconds': [0, 0]}, {'pointsSeconds': [1, 0]},
                   {'pointsSeconds': [False, .01]}, {'pointsSeconds': [0, math.nan]},
                   {'pointsSeconds': [0, 1e-300]}, {'maximumAdjacentFactor': .99},
                   {'minimumPeriodSeconds': 0}, {'maximumPeriodSeconds': .11},
                   {'domainEndSeconds': 61}, {'queryEndSeconds': 0}, {'queryStartSeconds': -.01}]
        for patch in patches:
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                jitter_reference.script({**deepcopy(base), **patch})


class JitterProtocolTests(unittest.TestCase):
    def setUp(self):
        self.case = jitter_catalog.make_case('constant', [1/128] * 2)
        self.raw = '\n'.join(['begin\tjitter-reference-v1', 'count\t3', 'point\t1\t0',
            'point\t2\t0.0078125', 'point\t3\t0.015625', 'periodCount\t2',
            'meanPeriod\t0.0078125', 'local\t0', 'absolute\t0', 'rap\t--undefined--',
            'ppq5\t--undefined--', 'ddp\t--undefined--', 'end\tjitter-reference-v1', ''])

    def test_zero_and_unavailable_remain_distinct(self):
        result = jitter_reference.parse(self.raw, self.case)
        self.assertEqual(result['absolute'], 0.)
        self.assertEqual(result['local'], 0.)
        self.assertIsNone(result['rap'])

    def test_missing_extra_reordered_and_corrupted_records_fail(self):
        replacements = [('begin\tjitter-reference-v1\n', ''), ('count\t3', 'count\t4'),
                        ('point\t2\t', 'point\t1\t'), ('point\t2\t0.0078125', 'point\t2\t0.008'),
                        ('periodCount\t2', 'periodCount\t02'), ('periodCount\t2', 'periodCount\t4'),
                        ('meanPeriod\t0.0078125', 'meanPeriod\t--undefined--'),
                        ('local\t0', 'local\t--undefined--'), ('ddp\t--undefined--', 'ddp\t0'),
                        ('end\tjitter-reference-v1', 'extra\t0\nend\tjitter-reference-v1')]
        for before, after in replacements:
            with self.subTest(before=before), self.assertRaises(ValueError):
                jitter_reference.parse(self.raw.replace(before, after), self.case)

    def test_nonfinite_negative_and_undefined_count_fail(self):
        for value in ('nan', 'inf', '-inf', '-1', ' 0', '0 ', '0_0', '+0', '00', '٠'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                jitter_reference.parse(self.raw.replace('local\t0', 'local\t' + value), self.case)
        with self.assertRaises(ValueError):
            jitter_reference.parse(self.raw.replace('periodCount\t2', 'periodCount\t--undefined--'), self.case)


class JitterFixtureVerificationTests(unittest.TestCase):
    canonical = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Jitter'

    def test_all_canonical_evidence_reconstructs_without_running_reference(self):
        result = jitter_verify.verify(self.canonical)
        self.assertEqual((result['cases'], result['canonicalFiles']), (69, 208))
        self.assertEqual((result['meanPeriods'], result['pairs'], result['rapWindows'], result['ppq5Windows']), (1132, 961, 822, 601))

    def test_rehashed_wrong_reference_answer_fails_independent_equations(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'fixtures'
            shutil.copytree(self.canonical, target)
            path = target / 'constant-5.raw.txt'
            original = path.read_text()
            self.assertIn('local\t0\n', original)
            path.write_text(original.replace('local\t0\n', 'local\t0.5\n'))
            manifest_path = target / 'manifest.json'
            manifest = json.loads(manifest_path.read_text())
            manifest['files'][path.name] = jitter_reference.digest(path.read_bytes())
            manifest_path.write_bytes(jitter_reference.canonical(manifest))
            with self.assertRaisesRegex(ValueError, 'local error'):
                jitter_verify.verify(target)

    def test_extra_file_missing_file_and_symlink_rejected(self):
        for mutation in ('extra', 'missing', 'symlink'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / 'fixtures'
                shutil.copytree(self.canonical, target)
                path = target / 'constant-5.raw.txt'
                if mutation == 'extra': (target / 'unexpected.json').write_text('{}')
                else:
                    path.unlink()
                    if mutation == 'symlink': path.symlink_to(self.canonical / path.name)
                with self.assertRaises(ValueError): jitter_verify.verify(target)

    def test_rehashed_wrong_neighborhood_membership_cannot_replace_oracle(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'fixtures'
            shutil.copytree(self.canonical, target)
            path = target / 'split-runs.json'
            payload = json.loads(path.read_text())
            payload['oracle']['pairIndices'].append(2)
            payload['fixtureIdentity'] = jitter_reference.digest(jitter_reference.canonical(
                {k: v for k, v in payload.items() if k != 'fixtureIdentity'}))
            path.write_bytes(jitter_reference.canonical(payload))
            manifest_path = target / 'manifest.json'
            manifest = json.loads(manifest_path.read_text())
            manifest['files'][path.name] = jitter_reference.digest(path.read_bytes())
            manifest_path.write_bytes(jitter_reference.canonical(manifest))
            with self.assertRaisesRegex(ValueError, 'cannot be independently reconstructed'):
                jitter_verify.verify(target)


if __name__ == '__main__': unittest.main()
