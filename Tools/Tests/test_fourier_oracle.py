"""Independent definition/fixture checks; expected anchors do not use native FFT output."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('fourier_oracle', ROOT / 'Tools/Fourier/oracle.py')
oracle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(oracle)


class FourierOracleTests(unittest.TestCase):
    def test_direct_definition_matches_hand_computed_endpoints_and_complex_rotation(self):
        anchors = [([1,0,0,0], [1,1,1,1]), ([1,1,1,1], [4,0,0,0]),
                   ([1,-1,1,-1], [0,0,4,0]), ([1,1j,-1,-1j], [0,4,0,0])]
        for source, expected in anchors:
            for actual, wanted in zip(oracle.direct_dft(source), expected):
                self.assertLess(abs(actual-wanted), 1e-14)
            for actual, wanted in zip(oracle.direct_dft(expected, inverse=True), source):
                self.assertLess(abs(actual-wanted), 1e-14)

    def test_oracle_rejects_unbounded_work_and_nonfinite_inputs(self):
        for values, bins in [([],None), ([0]*129,None), ([0]*256,list(range(17))),
                             ([float('nan')],None), ([0,1],[2]), ([0,1],[-1]), ([0,1],[True])]:
            with self.assertRaises(ValueError):
                oracle.direct_dft(values,bins)
        self.assertEqual(oracle.direct_dft([1]+[0]*255,[0,1,255]), [1,1,1])

    def test_committed_oracle_regenerates_independently(self):
        saved = json.loads(oracle.OUTPUT.read_text())
        fresh = oracle.generate()
        oracle.verify(saved,fresh)
        self.assertEqual(len(saved['cases']),192)
        for precision in ['float32','float64']:
            self.assertEqual({c['length'] for c in saved['cases'] if c['precision']==precision},set(oracle.LENGTHS))
        changed = copy.deepcopy(saved)
        changed['cases'][0]['expected'][0][0] += 0.1
        with self.assertRaises(ValueError):
            oracle.verify(changed,fresh)
        changed = copy.deepcopy(saved)
        changed['cases'][0]['maximumAbsoluteError'] *= 10
        with self.assertRaises(ValueError):
            oracle.verify(changed,fresh)
        changed = copy.deepcopy(saved)
        changed['cases'].pop()
        with self.assertRaises(ValueError):
            oracle.verify(changed,fresh)
