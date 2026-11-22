import hashlib
import itertools
import json
import math
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Harmonics import benchmark, reference


def observations():
    rows = []
    for rate, periods, geometry in itertools.product((16000, 44100, 48000), (3, 5), ('near', 'ordinary')):
        case = benchmark.expected_configuration(rate, periods, geometry)
        f0 = case['excitationHz']
        contributions = []
        for rank, (hz, bw) in enumerate(((case['firstResonanceHz'], 90), (1500, 110)), 1):
            coefficients = reference.pole(rate, hz, bw)
            contributions.append(dict(number=rank, frequencyHz=hz, bandwidthHz=bw,
                                      firstGainDB=reference.gain_db(coefficients, rate, f0),
                                      secondGainDB=reference.gain_db(coefficients, rate, 2 * f0),
                                      nearResonance=rank == 1 and geometry == 'near'))
        raw = 3.0
        corrected = raw + sum(p['secondGainDB'] - p['firstGainDB'] for p in contributions)
        rows.append(dict(name=case['name'], configuration=case, measuredPitchHz=f0,
                         windowSamples=round(rate * periods / f0), rawDB=raw, correctedDB=corrected,
                         contributions=contributions))
    return rows


class HarmonicEvidenceTests(unittest.TestCase):
    def test_quantized_samples_and_known_source_match_registered_reference(self):
        fixture = json.loads(reference.OUTPUT.read_bytes())
        self.assertEqual({r['name'] for r in fixture['cases']}, {c[0] for c in reference.CASES})
        for row in fixture['cases']:
            with self.subTest(case=row['name']):
                samples = row['pcm16']
                self.assertEqual(len(samples), row['periods'] * row['periodSamples'])
                data = struct.pack('<' + 'h' * len(samples), *samples)
                self.assertEqual(hashlib.sha256(data).hexdigest(), row['pcm16LESHA256'])
                for amplitude, corrected in zip(row['sourcePeaksFS'], row['correctedDBFS'], strict=True):
                    self.assertAlmostEqual(20 * math.log10(amplitude), corrected, delta=.004)

    def test_matrix_requires_unique_configuration_and_complete_coverage(self):
        rows = observations()
        benchmark.validate_cases(rows)
        for invalid in (rows[:-1], rows + [rows[0]]):
            with self.assertRaises(ValueError):
                benchmark.validate_cases(invalid)
        rows[0]['configuration']['profile']['formants']['order'] = 12
        with self.assertRaises(ValueError):
            benchmark.validate_cases(rows)

    def test_rejects_changed_dependency_digest_and_fit_support(self):
        for key in ('rawIdentity', 'correctedIdentity', 'windowSamples'):
            with self.subTest(key=key):
                rows = observations()
                if key == 'windowSamples':
                    rows[0][key] += 1
                else:
                    rows[0]['configuration'][key]['sha256'] = '0' * 64
                with self.assertRaises(ValueError):
                    benchmark.validate_cases(rows)

    def test_rejects_consistent_scalar_difference_with_incorrect_per_pole_gains(self):
        rows = observations()
        for field in ('firstGainDB', 'secondGainDB'):
            rows[0]['contributions'][0][field] += 1
        with self.assertRaises(ValueError):
            benchmark.validate_cases(rows)

    def test_geometry_and_finite_readouts_are_verified(self):
        for field, invalid in (('nearResonance', False), ('bandwidthHz', -1), ('frequencyHz', 10000)):
            with self.subTest(field=field):
                rows = observations()
                rows[0]['contributions'][0][field] = invalid
                with self.assertRaises(ValueError):
                    benchmark.validate_cases(rows)
        for key in ('rawDB', 'correctedDB', 'measuredPitchHz'):
            rows = observations()
            rows[0][key] = math.inf
            with self.assertRaises(ValueError):
                benchmark.validate_cases(rows)

    def test_cost_comparison_preserves_signed_differences_and_boundary(self):
        row = observations()[0]
        for mode, metrics in [('timing', ('wallClock', 'cpuTotal')),
                              ('allocation', ('mallocCountTotal', 'mallocBytesCount'))]:
            data = {f'HarmonicDifference.{stage}.{row["name"]}': {m: {'p50': value} for m in metrics}
                    for stage, value in [('Complete', 10), ('YINAndBurg', 12)]}
            comparison = benchmark.comparisons(data, [row], mode)
            self.assertEqual([item['metric'] for item in comparison], list(metrics))
            self.assertTrue(all(item['differenceOfTrialMediansPerFrame'] == -2 for item in comparison))
        measured = benchmark.throughput('Complete', row, {'p50': 500000, 'p99': 1000000})
        self.assertEqual(measured['framesPerSecondAtP50Latency'], 2000)
        self.assertEqual(measured['framesPerSecondAtP99Latency'], 1000)
        self.assertEqual(measured['sourceSeconds'], .05)
