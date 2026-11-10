"""Hand-enumerated timing/coverage contracts for independent SWIPE evidence."""
import math
import copy
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'SWIPE'))
import swipe_catalog as catalog
import swipe_reference as reference
from swipe_verify import verify_record


def frame(index, start, observed, required, frequency=100., status='voiced', reason=None):
    return {'frameIndex': index, 'startSample': start, 'observedSampleCount': observed,
            'requiredSampleCount': required, 'frequencyHz': frequency, 'status': status, 'reason': reason}


class SWIPEReferenceTests(unittest.TestCase):
    def test_short_yin_support_uses_explicit_valid_hop(self):
        case = next(c for c in catalog.cases() if c['name'] == 'window-boundary-250')
        profile, rows = reference.baseline(catalog.source_samples(case), case['profile'])
        self.assertEqual(case['profile']['hopLength'], 160)
        self.assertEqual(profile['hopLength'], 129)
        self.assertEqual(rows[0]['requiredSampleCount'], 129)
        self.assertEqual(rows[1]['startSample'], 129)

    def test_record_verification_rejects_changed_stage_profile_and_denominator(self):
        case = next(c for c in catalog.cases() if c['name'] == 'insufficient-one')
        record, encoded = reference.evaluate(case, reference.reference_identity())
        self.assertEqual(verify_record(record, case), encoded)
        for field in ('kernel', 'profile', 'denominator', 'source'):
            changed = copy.deepcopy(record)
            if field == 'kernel':
                changed['kernelProbes'][0]['coefficients'][0] = .01
            elif field == 'profile':
                changed['profile']['strengthThreshold'] = .5
            elif field == 'denominator':
                changed['metrics']['partialFrameCount'] = 0
            else:
                changed['reference']['implementationSHA256'] = '0' * 64
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'mismatch'):
                verify_record(changed, case)

    def test_matching_uses_actual_midpoints_and_keeps_unavailable_full_frames(self):
        swipe = [frame(0, 0, 12, 12), frame(1, 4, 12, 12, None, 'unvoiced', 'silence'),
                 frame(2, 8, 3, 12, None, 'unavailable', 'insufficientData')]
        yin = [frame(i, 4 * i, 5, 5) for i in range(4)]
        yin.append(frame(4, 16, 2, 5, None, 'unavailable', 'insufficientData'))
        result = reference.align(swipe, yin, 4, 100)
        self.assertEqual([(p['swipeFrameIndex'], p['yinFrameIndex']) for p in result['pairs']], [(0, 1), (1, 2)])
        self.assertEqual(result['unmatchedSWIPEFrameIndices'], [2])
        self.assertEqual(result['unmatchedYINFrameIndices'], [0, 3, 4])
        first, second = result['pairs']
        self.assertEqual(first['yinMinusSWIPECenterSamples'], .5)
        self.assertEqual(first['supportOverlapSamples'], 5)
        self.assertEqual(first['swipeEarliestDelaySeconds'], .06)
        self.assertEqual(first['yinEarliestDelaySeconds'], .025)
        self.assertEqual(first['swipeMinusYINCents'], 0.)
        self.assertIsNone(second['swipeMinusYINCents'])
        self.assertFalse(result['sameHopIsSameLatency'])

    def test_matching_tie_is_earlier_and_no_pair_exceeds_half_hop(self):
        swipe = [frame(0, 2, 4, 4), frame(1, 50, 4, 4)]
        yin = [frame(0, 0, 4, 4), frame(1, 4, 4, 4)]
        result = reference.align(swipe, yin, 4, 100)
        self.assertEqual(result['matchedFrameCount'], 1)
        self.assertEqual(result['pairs'][0]['yinFrameIndex'], 0)
        self.assertEqual(result['pairs'][0]['centerDistanceSeconds'], .02)
        self.assertEqual(result['unmatchedSWIPEFrameIndices'], [1])
        self.assertEqual(result['unmatchedYINFrameIndices'], [1])

    def test_metrics_preserve_partial_and_missing_denominators(self):
        case = {'acceptanceGroup': 'clean-tone', 'profile': {'sampleRate': 100},
                'source': {'kind': 'tone', 'frequencyHz': 100., 'sampleCount': 40}}
        rows = [frame(0, 0, 12, 12), frame(1, 4, 12, 12, 200., 'uncertain', 'lowConfidence'),
                frame(2, 8, 12, 12, None, 'unvoiced', 'silence'),
                frame(3, 12, 3, 12, None, 'unavailable', 'insufficientData')]
        result = reference.metrics(case, rows)
        self.assertEqual(result['potentialFrameCount'], 4)
        self.assertEqual(result['fullSupportFrameCount'], 3)
        self.assertEqual(result['partialFrameCount'], 1)
        self.assertEqual(result['availableFrameCount'], 2)
        self.assertEqual(result['voicedFrameCount'], 1)
        self.assertEqual(result['availableCoverageIncludingPartial'], .5)
        self.assertEqual(result['voicedCoverageOfFullSupport'], 1 / 3)
        self.assertEqual(result['knownTargetFullSupportCount'], 3)
        self.assertEqual(result['knownTargetAvailableCount'], 2)
        self.assertEqual(result['availableGrossErrorCount'], 1)
        self.assertEqual(result['availableOctaveErrorCount'], 1)
        self.assertEqual(result['voicedGrossErrorCount'], 0)
        self.assertEqual(result['fineErrorCount'], 1)
        self.assertEqual(result['meanFineAbsoluteCents'], 0.)
        self.assertEqual(result['maximumAvailableAbsoluteCents'], 1200.)
        self.assertEqual(result['toneQualityGoalExceededCount'], 1)
        self.assertEqual(result['toneQualityGoalAvailableDenominator'], 2)
        self.assertEqual(result['unavailabilityAndWarningReasons'],
                         {'lowConfidence': 1, 'silence': 1, 'insufficientData': 1})

    def test_undefined_truth_is_not_zero_or_a_fine_error_success(self):
        case = {'acceptanceGroup': 'unknown-speech-truth', 'profile': {'sampleRate': 100},
                'source': {'kind': 'licensed-speech', 'frequencyHz': 100., 'sampleCount': 40}}
        result = reference.metrics(case, [frame(0, 0, 12, 12)])
        self.assertEqual(result['knownTargetFullSupportCount'], 0)
        self.assertEqual(result['fineErrorCount'], 0)
        self.assertIsNone(result['meanFineAbsoluteCents'])
        self.assertEqual(result['truthBasis'], 'unknown-real-speech')
        case['source']['kind'] = 'octave-jump'
        self.assertEqual(catalog.target_hz(case, 0, 20), 120.)
        self.assertEqual(catalog.target_hz(case, 20, 20), 240.)
        self.assertIsNone(catalog.target_hz(case, 19, 2))

    def test_catalog_inputs_are_finite_reproducible_and_float32_is_explicit(self):
        cases = catalog.cases()
        self.assertEqual(len(cases), len({c['name'] for c in cases}))
        selected = next(c for c in cases if c['name'] == 'float32-breathy')
        samples = catalog.source_samples(selected)
        self.assertEqual(samples, catalog.source_samples(selected))
        self.assertTrue(all(math.isfinite(x) and struct.unpack('<f', struct.pack('<f', x))[0] == x for x in samples))
        for name in ('silence', 'constant', 'insufficient-one'):
            case = next(c for c in cases if c['name'] == name)
            values = catalog.source_samples(case)
            self.assertEqual(len(values), case['source']['sampleCount'])
        self.assertEqual({c['profile']['sampleRate'] for c in cases if c['name'].startswith('grid-')},
                         {16000, 44100, 48000})
        self.assertEqual({c['profile']['hopLength'] for c in cases
                          if c['name'].startswith('grid-16000')}, {80, 160, 320})


if __name__ == '__main__':
    unittest.main()
