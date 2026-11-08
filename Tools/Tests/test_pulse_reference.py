"""Independent protocol anchors and corruption controls; no Praat launch in tests."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pulse_reference_contract', ROOT / 'Tools/Pulses/reference.py')
pulse_reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pulse_reference)


class PulseReferenceTests(unittest.TestCase):
    def setUp(self):
        self.pitch = {'domainEndSeconds': .02, 'firstCenterSeconds': .005,
                      'stepSeconds': .01, 'ceilingHz': 1000., 'frequenciesHz': [200., 0.]}
        # Hand-enumerated protocol: two F0 frames and three raw pulse landmarks.
        self.raw = '\n'.join([
            'begin\tpulse-reference-v2', 'input\t16000\t320',
            'periodSettings\t0.0001\t0.02\t1.3',
            'pitch\t2\t0.005\t0.01\t0\t0.02',
            'f0\t1\t0.005\t200', 'f0\t2\t0.015\t--undefined--',
            'count\t3', 'pulse\t1\t-0.001', 'pulse\t2\t0.004',
            'pulse\t3\t0.02', 'amplitudes\tinsufficientData\t0', 'end\tpulse-reference-v2', ''])

    def test_raw_boundary_landmarks_remain_explicit(self):
        result = pulse_reference.parse(self.raw, self.pitch, 16000, 320)
        self.assertEqual(result['pulseTimesSeconds'], [-.001, .004, .02])
        self.assertEqual(result['outsideDomainIndices'], [0, 2])
        self.assertEqual(result['unit'], 'seconds')
        self.assertTrue(result['injectedF0Verified'])

    def test_unvoiced_is_not_numeric_zero_in_reference_protocol(self):
        with self.assertRaises(ValueError):
            pulse_reference.parse(self.raw.replace('--undefined--', '0'), self.pitch, 16000, 320)
        with self.assertRaises(ValueError):
            pulse_reference.parse(self.raw.replace('\t200\n', '\t--undefined--\n'), self.pitch, 16000, 320)

    def test_empty_points_are_valid_with_complete_f0_evidence(self):
        raw = self.raw[:self.raw.index('count\t')] + 'count\t0\namplitudes\tinsufficientData\t0\nend\tpulse-reference-v2\n'
        result = pulse_reference.parse(raw, self.pitch, 16000, 320)
        self.assertEqual(result['pulseTimesSeconds'], [])
        self.assertEqual(result['outsideDomainIndices'], [])

    def test_missing_reordered_duplicate_and_extra_records_fail(self):
        corruptions = [
            self.raw.replace('begin\tpulse-reference-v2\n', ''),
            self.raw.replace('end\tpulse-reference-v2\n', ''),
            self.raw.replace('count\t3', 'count\t2'),
            self.raw.replace('pulse\t2\t0.004', 'pulse\t1\t0.004'),
            self.raw.replace('f0\t2\t0.015\t--undefined--\n', ''),
            self.raw.replace('f0\t2\t', 'f0\t1\t'),
            self.raw.replace('pulse\t3\t0.02', 'pulse\t3\t-0.002'),
            self.raw.replace('pulse\t2\t0.004', 'pulse\t2\t-0.001'),
            self.raw.replace('end\tpulse-reference-v2', 'extra\t1\nend\tpulse-reference-v2'),
            self.raw.replace('count\t3', 'count\t03'),
        ]
        for raw in corruptions:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                pulse_reference.parse(raw, self.pitch, 16000, 320)

    def test_pcm_f0_axis_and_frequency_corruption_fail(self):
        for old, new in [('input\t16000', 'input\t48000'), ('16000\t320', '16000\t319'),
                         ('pitch\t2\t0.005', 'pitch\t3\t0.005'),
                         ('0.01\t0\t0.02', '0.01\t0.001\t0.02'),
                         ('f0\t2\t0.015', 'f0\t2\t0.016'), ('\t200\n', '\t201\n')]:
            with self.subTest(old=old), self.assertRaises(ValueError):
                pulse_reference.parse(self.raw.replace(old, new), self.pitch, 16000, 320)

    def test_nonfinite_undefined_and_unbounded_pulses_fail(self):
        for value in ['nan', 'inf', '-inf', '--undefined--', '0,004', '-0.101', '0.121']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                pulse_reference.parse(self.raw.replace('pulse\t2\t0.004', 'pulse\t2\t' + value),
                                      self.pitch, 16000, 320)

    def test_invalid_input_metadata_fails_before_execution(self):
        for patch in [{'extra': 1}, {'stepSeconds': True}, {'domainEndSeconds': .03},
                      {'firstCenterSeconds': 0.}, {'stepSeconds': .1},
                      {'ceilingHz': 5000.}, {'frequenciesHz': []},
                      {'frequenciesHz': [1000., 0.]}, {'frequenciesHz': [True, 0.]},
                      {'frequenciesHz': [float('nan'), 0.]}]:
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                pulse_reference.validate_pitch({**deepcopy(self.pitch), **patch}, 16000, 320)
        for rate, count in [(True, 320), (16000., 320), (16000, True), (16000, 80001)]:
            with self.subTest(rate=rate, count=count), self.assertRaises(ValueError):
                pulse_reference.validate_pitch(self.pitch, rate, count)

    def test_pitch_interchange_has_one_explicit_candidate_per_frame(self):
        text = pulse_reference.encode_pitch(self.pitch, 16000, 320).decode()
        self.assertIn('Object class = "Pitch 1"', text)
        self.assertTrue(text.endswith('1\n1\n200.0\n0.9\n1\n1\n0.0\n0\n'))
        self.assertNotIn('\n.', text)

    def test_interior_f0_grid_does_not_require_fabricated_edge_frames(self):
        pitch = {**self.pitch, 'domainEndSeconds': .1, 'firstCenterSeconds': .02,
                 'frequenciesHz': [150.] * 4}
        pulse_reference.validate_pitch(pitch, 16000, 1600)
        encoded = pulse_reference.encode_pitch(pitch, 16000, 1600).decode()
        self.assertEqual(encoded.count('150.0\n'), 4)

    def test_amplitudes_bind_to_interior_observed_pulses(self):
        raw = self.raw[:self.raw.index('count\t')] + '\n'.join([
            'count\t5', 'pulse\t1\t0.002', 'pulse\t2\t0.006', 'pulse\t3\t0.010',
            'pulse\t4\t0.014', 'pulse\t5\t0.018', 'amplitudes\tcomplete\t3',
            'amplitude\t1\t0.006\t0.2', 'amplitude\t2\t0.010\t0.3',
            'amplitude\t3\t0.014\t0.4', 'end\tpulse-reference-v2', ''])
        result = pulse_reference.parse(raw, self.pitch, 16000, 320)
        self.assertEqual([a['pulseIndex'] for a in result['amplitudes']], [1, 2, 3])
        self.assertEqual([a['rmsAmplitude'] for a in result['amplitudes']], [.2, .3, .4])
        for old, new in [('amplitudes\tcomplete\t3', 'amplitudes\tcomplete\t2'),
                         ('amplitudes\tcomplete', 'amplitudes\tinsufficientData'),
                         ('amplitude\t1\t0.006', 'amplitude\t1\t0.002'),
                         ('amplitude\t3\t0.014', 'amplitude\t3\t0.010'),
                         ('amplitude\t3\t0.014', 'amplitude\t3\t0.015'),
                         ('amplitude\t2\t0.010\t0.3', 'amplitude\t2\t0.010\t0'),
                         ('amplitude\t2\t0.010\t0.3', 'amplitude\t2\t0.010\tnan')]:
            with self.subTest(old=old, new=new), self.assertRaises(ValueError):
                pulse_reference.parse(raw.replace(old, new), self.pitch, 16000, 320)

    def test_period_settings_are_explicit_order_independent_and_bounded(self):
        reordered = dict(reversed(list(pulse_reference.PERIOD_DEFAULTS.items())))
        pulse_reference.parse(self.raw, self.pitch, 16000, 320, reordered)
        for patch in [{'minimumSeconds': True}, {'minimumSeconds': .02},
                      {'maximumSeconds': .2}, {'maximumAdjacentFactor': .9}, {'unknown': 1}]:
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                pulse_reference.validate_period_settings({**pulse_reference.PERIOD_DEFAULTS, **patch})
        with self.assertRaises(ValueError):
            pulse_reference.parse(self.raw.replace('0.02\t1.3', '0.02\t1.5'), self.pitch, 16000, 320)


if __name__ == '__main__':
    unittest.main()
