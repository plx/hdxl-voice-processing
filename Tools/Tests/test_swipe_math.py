"""Closed-form checks independent of the eventual native SWIPE implementation."""
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'SWIPE'))
import swipe_math as oracle


class SWIPEMathematicalAnchors(unittest.TestCase):
    def test_erb_closed_form_and_round_trips(self):
        self.assertEqual(oracle.erb_rate(0), 0.)
        self.assertEqual(oracle.erb_frequency(0), 0.)
        # 1 + 2061/229 = 10; these are direct equation-7 anchors.
        self.assertAlmostEqual(oracle.erb_rate(2061), 21.4, places=13)
        self.assertAlmostEqual(oracle.erb_frequency(21.4), 2061., places=11)
        for frequency in [1e-12, 20., 50., 229., 440., 4000., 24000., 96000.]:
            with self.subTest(frequency=frequency):
                self.assertAlmostEqual(
                    oracle.erb_frequency(oracle.erb_rate(frequency)) / frequency,
                    1., places=13)

    def test_prime_set_includes_two_but_not_one_or_composites(self):
        expected = {2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31}
        self.assertEqual({n for n in range(32) if oracle.is_prime(n)}, expected)

    def test_prime_peaks_and_valleys_have_hand_enumerated_weights(self):
        # Independently listed first/prime harmonics through the observed range.
        harmonics = [1, 2, 3, 5, 7, 11, 13]
        anchors = {0.: 0., .5: -.5, 1.: 1., 1.5: -1., 2.: 1.,
                   2.5: -1., 3.: 1., 3.5: -.5, 4.: 0., 4.5: -.5,
                   5.: 1., 6.: 0., 7.: 1., 9.: 0., 11.: 1.}
        for ratio, expected in anchors.items():
            with self.subTest(ratio=ratio):
                actual = math.fsum(oracle.harmonic_lobe(ratio, h) for h in harmonics)
                self.assertAlmostEqual(actual, expected, places=14)
        for ratio in [.25, .75, 1.25, 1.75]:
            self.assertEqual(oracle.harmonic_lobe(ratio, 1), 0.)
        self.assertAlmostEqual(oracle.harmonic_lobe(1.125, 1), math.sqrt(.5))

    def test_positive_part_normalization_preserves_negative_scores(self):
        # Full-kernel L2 normalization, abs(numerator), or probability clipping
        # would each fail these direct two-element inner-product examples.
        self.assertEqual(oracle.pitch_strength([2., 0.], [2., -4.]), 1.)
        self.assertEqual(oracle.pitch_strength([0., 2.], [2., -4.]), -2.)
        self.assertAlmostEqual(
            oracle.pitch_strength([3., 4.], [2., -1.]), .2, places=14)
        self.assertEqual(oracle.pitch_strength([0., 0.], [2., -1.]), None)
        self.assertEqual(oracle.pitch_strength([3., 4.], [0., -1.]), None)
        self.assertEqual(oracle.pitch_strength([0., 2.], [2., 0.]), 0.)

    def test_inner_product_scaling_is_safe_at_extreme_finite_scales(self):
        expected = oracle.pitch_strength([3., 4.], [2., -1.])
        for signal_scale in [1e-300, 1., 1e300]:
            for kernel_scale in [1e-300, 1., 1e300]:
                with self.subTest(signal=signal_scale, kernel=kernel_scale):
                    self.assertAlmostEqual(oracle.pitch_strength(
                        [3. * signal_scale, 4. * signal_scale],
                        [2. * kernel_scale, -kernel_scale]), expected, places=14)

    def test_window_pair_matches_eight_period_geometry(self):
        self.assertEqual(oracle.window_pair(16000, 250), (512, 1024, 0.))
        self.assertEqual(oracle.window_pair(16000, 125), (1024, 2048, 0.))
        low, high, weight = oracle.window_pair(16000, 250 / math.sqrt(2.))
        self.assertEqual((low, high), (512, 1024))
        self.assertAlmostEqual(weight, .5, places=14)
        for frequency in [50., 100., 190., 700., 2000.]:
            low, high, weight = oracle.window_pair(48000, frequency)
            self.assertTrue(low <= 8. * 48000 / frequency < high)
            self.assertAlmostEqual(
                low ** (1. - weight) * high ** weight,
                8. * 48000 / frequency, delta=1e-10)

    def test_invalid_math_inputs_are_explicit(self):
        for value in [True, float('nan'), float('inf'), -1.]:
            with self.assertRaises(ValueError):
                oracle.erb_rate(value)
            with self.assertRaises(ValueError):
                oracle.erb_frequency(value)
        with self.assertRaises(ValueError):
            oracle.erb_frequency(1e300)
        for args in [([], []), ([1.], []), ([-1.], [1.]), ([1.], [float('nan')])]:
            with self.assertRaises(ValueError):
                oracle.pitch_strength(*args)
        for args in [(0, 100), (16000, 0), (16000, 1e-300)]:
            with self.assertRaises(ValueError):
                oracle.window_pair(*args)


if __name__ == '__main__':
    unittest.main()
