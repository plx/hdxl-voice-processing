"""Independent Fourier, grid, kernel, refinement and support checks for #44."""
import cmath
import copy
import math
from pathlib import Path
import random
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'SWIPE'))
import swipe_oracle as oracle
from swipe_analytic import hann_tone_magnitude


class SWIPEOracleTests(unittest.TestCase):
    def test_closed_form_hann_tone_matches_direct_on_and_off_bin_dtft(self):
        for length in (32, 128):
            for signal_hz in (123.45, 250., 440.):
                for phase in (0., .73):
                    offset, rate = 193, 16000
                    samples = [math.sin(2 * math.pi * signal_hz * (j + offset) / rate + phase)
                               * (.5 - .5 * math.cos(2 * math.pi * j / length)) for j in range(length)]
                    for frequency in (0., 37.2, 125., signal_hz, 440., 8000.):
                        terms = [x * cmath.exp(-2j * math.pi * frequency * j / rate)
                                 for j, x in enumerate(samples)]
                        direct = abs(complex(math.fsum(z.real for z in terms), math.fsum(z.imag for z in terms)))
                        analytic = hann_tone_magnitude(frequency, signal_hz, rate, length, offset, phase)
                        self.assertAlmostEqual(analytic, direct, delta=2e-10)

    def test_recursive_fft_matches_direct_complex_dft(self):
        random_source = random.Random(4408)
        for count in [1, 2, 4, 8, 16, 32]:
            samples = [complex(random_source.uniform(-1, 1), random_source.uniform(-1, 1))
                       for _ in range(count)]
            actual = oracle.fft(samples)
            for k in range(count):
                terms = [x * cmath.exp(-2j * math.pi * k * j / count)
                         for j, x in enumerate(samples)]
                expected = complex(math.fsum(x.real for x in terms), math.fsum(x.imag for x in terms))
                self.assertLessEqual(abs(actual[k] - expected), 2e-13 * count)
        for samples in [[], [1., 2., 3.]]:
            with self.assertRaises(ValueError):
                oracle.fft(samples)

    def test_hann_analytic_dft_has_dc_and_two_adjacent_bins(self):
        count = 64
        window = [.5 - .5 * math.cos(2 * math.pi * j / count) for j in range(count)]
        for k, value in enumerate(oracle.fft(window)):
            expected = count / 2 if k == 0 else -count / 4 if k in (1, count - 1) else 0.
            self.assertLess(abs(value - expected), 3e-13)
        # A centered-bin complex exponential shifts this spectrum without
        # one-sided doubling or any normalization of the forward transform.
        for k, value in enumerate(oracle.fft([
                x * cmath.exp(2j * math.pi * 7 * j / count) for j, x in enumerate(window)])):
            expected = count / 2 if k == 7 else -count / 4 if k in (6, 8) else 0.
            self.assertLess(abs(value - expected), 3e-13)

    def test_interpolate_magnitude_before_square_root(self):
        actual = oracle.linear_magnitude_loudness([0., 4., 16.], [0., .5, 1., 1.5, 2.], 4, 4)
        for result, expected in zip(actual, [0., math.sqrt(2), 2., math.sqrt(10), 4.]):
            self.assertEqual(result, expected)

    def test_kernel_normalization_and_partial_prime_lobe(self):
        frequencies = [0., 50., 100., 150., 200., 250., 300., 350., 400., 440.]
        # The 5th harmonic's lower valley reaches 440 Hz although its peak
        # lies above the sampled band. This is deliberately not whole-lobe truncation.
        component = [0., -.5, 1., -1., 1., -1., 1., -.5, 0., .5 * math.cos(-1.2 * math.pi)]
        expected = [x / math.sqrt(f) if f else 0. for x, f in zip(component, frequencies)]
        norm = math.sqrt(sum(max(0., x) ** 2 for x in expected))
        actual = oracle.normalized_kernel(100., frequencies)
        for a, b in zip(actual, expected):
            self.assertAlmostEqual(a, b / norm, places=14)
        self.assertAlmostEqual(math.fsum(max(0., x) ** 2 for x in actual), 1., places=14)
        self.assertEqual(actual[0], 0.)
        self.assertEqual(actual[8], 0.)
        self.assertLess(actual[-1], 0.)

    def test_grid_exact_endpoints_and_coalescence(self):
        grid = oracle.candidate_grid(50., 100., 12)
        self.assertEqual(len(grid), 13)
        self.assertEqual((grid[0], grid[-1]), (50., 100.))
        self.assertAlmostEqual(grid[6], math.sqrt(50. * 100.))
        for ceiling in [100 * (1 - 2e-13), 100., 100 * (1 + 2e-13)]:
            grid = oracle.candidate_grid(50., ceiling, 12)
            self.assertEqual(len(grid), 13)
            self.assertEqual(grid[-1], ceiling)
            self.assertTrue(all(a < b for a, b in zip(grid, grid[1:])))

    def test_exact_window_optimum_omits_zero_weight_neighbor(self):
        layout = oracle.geometry(oracle.configuration(floor=250., ceiling=500., resolution=12))
        self.assertEqual(layout['windowLengths'], [256, 512])
        self.assertEqual(layout['requiredSampleCount'], 512)
        self.assertEqual(layout['candidateWindows'][0],
                         {'lowerLength': 512, 'upperLength': 1024, 'upperWeight': 0.})
        self.assertEqual(layout['erbFrequenciesHz'][0], 0.)
        self.assertLessEqual(layout['erbFrequenciesHz'][-1], 8000.)
        self.assertEqual(oracle.geometry(oracle.configuration())['requiredSampleCount'], 4096)

    def test_period_refinement_recovers_known_nonuniform_parabola(self):
        frequencies = [100., 125., 160.]
        strengths = [1 - 20 * (125 / f - 1.03) ** 2 for f in frequencies]
        frequency, strength, refined = oracle.refine(frequencies, strengths, 1)
        self.assertTrue(refined)
        self.assertAlmostEqual(frequency, 125 / 1.03, places=12)
        self.assertAlmostEqual(strength, 1., places=14)
        for values, index in [([1., 1., .5], 0), ([1., 1., .5], 1), ([.5, 1., 1.], 1),
                              ([1., 0., 1.], 1), ([None, 1., .5], 1), ([.5, 1., 2.], 2)]:
            self.assertEqual(oracle.refine(frequencies, values, index),
                             (frequencies[index], values[index], False))

    def test_profile_rejects_unknown_missing_and_inconsistent_fields(self):
        profile = oracle.configuration()
        oracle.validate(profile)
        for field in profile:
            bad = dict(profile)
            del bad[field]
            with self.subTest(missing=field), self.assertRaises(ValueError):
                oracle.validate(bad)
        for change in [{'surprise': 1}, {'definition': 'SWIPE'}, {'schemaVersion': True},
                       {'spectrumInterpolation': 'complex'}, {'sampleRate': True},
                       {'strengthThreshold': float('nan')}, {'candidatesPerOctave': 96.},
                       {'partialWindowPolicy': 'zeroPad'}, {'pitchFloorHz': 700.}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                oracle.validate({**profile, **change})
        for arguments in [dict(floor=100., ceiling=100.01), dict(rate=3999), dict(hop=0),
                          dict(resolution=193), dict(ceiling=5000.), dict(silence=-1.)]:
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                oracle.configuration(**arguments)

    def test_status_zero_silence_constant_and_partial_are_distinct(self):
        analyzer = oracle.PreparedOracle(oracle.configuration(rate=4000, floor=100., ceiling=500., resolution=12))
        support = analyzer.layout['requiredSampleCount']
        zero = analyzer.frame([0.] * support)
        self.assertEqual((zero['status'], zero['reason'], zero['frequencyHz']),
                         ('unvoiced', 'silence', None))
        self.assertEqual(zero['rms'], 0.)
        self.assertTrue(all(x is None for x in zero['candidateStrengths']))
        constant = analyzer.frame([.5] * support)
        self.assertEqual((constant['status'], constant['reason'], constant['frequencyHz']),
                         ('unvoiced', 'lowConfidence', None))
        self.assertTrue(all(x is not None for x in constant['candidateStrengths']))
        partial = analyzer.frame([.5] * (support - 1))
        self.assertEqual((partial['status'], partial['reason']), ('unavailable', 'insufficientData'))
        self.assertEqual(partial['windows'], [])
        self.assertIsNone(partial['rms'])
        impulse = [1.] + [0.] * (support - 1)
        edge = analyzer.frame(impulse)
        self.assertGreater(edge['rms'], 0.)
        self.assertEqual((edge['status'], edge['reason'], edge['frequencyHz']),
                         ('unavailable', 'analysisFailure', None))
        self.assertTrue(all(x is None for x in edge['candidateStrengths']))
        for samples in [[0.] * (support + 1), [float('nan')], [float('inf')], [True]]:
            with self.assertRaises(ValueError):
                analyzer.frame(samples)

    def test_stream_support_tail_and_no_input(self):
        profile = oracle.configuration(rate=4000, floor=100., ceiling=500., resolution=12, hop=40)
        analyzer = oracle.PreparedOracle(profile)
        count = analyzer.layout['requiredSampleCount']
        samples = [.5 * math.sin(2 * math.pi * 250 * j / 4000) for j in range(count + 80)]
        rows = analyzer.stream(samples)
        self.assertEqual([r['startSample'] for r in rows], [0, 40, 80, 120])
        self.assertEqual([r['observedSampleCount'] for r in rows], [count] * 3 + [count - 40])
        self.assertTrue(all(r['status'] == 'voiced' for r in rows[:3]))
        self.assertEqual(rows[-1]['reason'], 'insufficientData')
        self.assertEqual(analyzer.stream([]), [])
        discard = oracle.PreparedOracle({**profile, 'partialWindowPolicy': 'discard'})
        self.assertEqual(discard.stream(samples), rows[:-1])
        with self.assertRaises(ValueError):
            discard.stream([float('nan')])
        # Preparation owns the profile; caller mutation cannot alter a run.
        snapshot = copy.deepcopy(analyzer.profile)
        profile['hopLength'] = 1
        self.assertEqual(analyzer.profile, snapshot)

    def test_threshold_changes_eligibility_without_replacing_estimate(self):
        profile = oracle.configuration(rate=4000, floor=100., ceiling=500., resolution=24)
        analyzer = oracle.PreparedOracle(profile)
        samples = [.5 * math.sin(2 * math.pi * 250 * j / 4000)
                   for j in range(analyzer.layout['requiredSampleCount'])]
        accepted = analyzer.frame(samples)
        weak = oracle.PreparedOracle({**profile, 'strengthThreshold': .99}).frame(samples)
        self.assertEqual((accepted['status'], weak['status']), ('voiced', 'uncertain'))
        self.assertEqual(accepted['frequencyHz'], weak['frequencyHz'])
        self.assertEqual(accepted['pitchStrength'], weak['pitchStrength'])
        self.assertEqual(weak['reason'], 'lowConfidence')


if __name__ == '__main__':
    unittest.main()
