"""Frozen numerical budgets and availability/timing failures in workload probes."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'SWIPE'))
import probe_audit as audit


class SWIPEProbeAuditTests(unittest.TestCase):
    def setUp(self):
        self.expected = dict(frameIndex=0, startSample=0, observedSamples=2048,
                             status='voiced', frequencyHz=125., strength=.5)

    def test_uses_existing_algorithm_budgets_and_rejects_larger_errors(self):
        self.assertEqual(audit.BUDGETS, {
            'SWIPEPrime': dict(frequencyHz=.01, strength=2e-7),
            'YINFFT': dict(frequencyHz=.001, strength=1e-9)})
        for algorithm, budgets in audit.BUDGETS.items():
            audit.compare_probe(self.expected, self.expected, algorithm)
            for field, budget in budgets.items():
                with self.subTest(algorithm=algorithm, field=field):
                    within = dict(self.expected)
                    within[field] += budget / 2
                    audit.compare_probe(within, self.expected, algorithm)
                    outside = dict(self.expected)
                    outside[field] += budget * 2
                    with self.assertRaises(ValueError):
                        audit.compare_probe(outside, self.expected, algorithm)

    def test_missing_nonfinite_and_false_availability_fail_closed(self):
        for field in ('frequencyHz', 'strength'):
            for value in (None, True, float('nan'), float('inf')):
                with self.subTest(field=field, value=value):
                    actual = dict(self.expected, **{field: value})
                    with self.assertRaises(ValueError):
                        audit.compare_probe(actual, self.expected, 'SWIPEPrime')
            malformed = dict(self.expected, **{field: float('nan')})
            with self.assertRaises(ValueError):
                audit.compare_probe(self.expected, malformed, 'SWIPEPrime')
        unavailable = dict(self.expected, status='unvoiced', frequencyHz=None, strength=None)
        omitted = {k: v for k, v in unavailable.items() if v is not None}
        audit.compare_probe(omitted, unavailable, 'SWIPEPrime')
        with self.assertRaises(ValueError):
            audit.compare_probe(dict(unavailable, frequencyHz=0.), unavailable, 'SWIPEPrime')

    def test_support_grid_and_status_are_exact(self):
        for field, value in [('frameIndex', False), ('frameIndex', 1), ('startSample', 1),
                             ('observedSamples', 2047), ('status', 'uncertain')]:
            with self.subTest(field=field):
                actual = copy.deepcopy(self.expected)
                actual[field] = value
                with self.assertRaises(ValueError):
                    audit.compare_probe(actual, self.expected, 'SWIPEPrime')
