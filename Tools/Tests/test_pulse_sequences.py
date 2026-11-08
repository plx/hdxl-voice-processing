"""Hand-calculated eligibility and energy anchors, independent of pulse tracking."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = "import sys,math;sys.path.insert(0,'Tools/Pulses');import sequences\n"


class PulseSequenceTests(unittest.TestCase):
    def check(self, code):
        result = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bad_pair_does_not_erase_individual_periods(self):
        self.check("""
r=sequences.eligibility([0.,.01,.03,.04,.05],[0]*5,.06,settings={
 'minimumSeconds':.001,'maximumSeconds':.025,'maximumAdjacentFactor':1.3})
assert [x['eligible'] for x in r['periods']]==[True]*4
assert [x['eligible'] for x in r['pairs']]==[False,False,True]
assert r['eligiblePeriodCount']==4 and r['eligiblePairCount']==1
""")

    def test_breaks_are_retained_without_stitching_neighbors(self):
        self.check("""
r=sequences.eligibility([.01,.02,.03,.04,.05,.06],[0,0,0,1,1,1],.08,broken_intervals=[1])
assert [x['eligible'] for x in r['periods']]==[True,False,False,True,True]
assert r['periods'][1]['reasons']==['trackingFailure']
assert r['periods'][2]['reasons']==['differentRun']
assert [x['eligible'] for x in r['pairs']]==[False,False,False,True]
r=sequences.eligibility([-.001,.004,.009,.02],[0,0,None,1],.02)
assert [p['eligible'] for p in r['periods']]==[False]*3
assert r['rawPeriodCount']==3
""")

    def test_constant_and_impulse_have_closed_form_rms(self):
        self.check("""
r=sequences.hann_rms([.25]*10,1000,.0035,.01,.01)
assert r['status']=='available' and abs(r['rmsAmplitude']-.25)<1e-15
x=[0.]*10;x[3]=1.
r=sequences.hann_rms(x,1000,.0035,.01,.01)
assert abs(r['rmsAmplitude']-math.sqrt(2/3))<1e-14
assert r['firstSampleIndex']==1 and r['lastSampleIndex']==5
for gain in (-1.,.1,1e-200):
 s=sequences.hann_rms([v*gain for v in x],1000,.0035,.01,.01)
 assert math.isclose(s['rmsAmplitude'],abs(gain)*math.sqrt(2/3),rel_tol=1e-13)
""")

    def test_boundary_silence_and_too_few_samples_are_explicit(self):
        self.check("""
assert sequences.hann_rms([0.]*10,1000,.0035,.01,.01)['reason']=='silence'
assert sequences.hann_rms([1.]*10,1000,.0005,.01,.01)['reason']=='insufficientSupport'
assert sequences.hann_rms([1.]*10,1000,.0035,.001,.001)['reason']=='insufficientData'
for times,runs,breaks in [([.01,.01],[0,0],[]),([.01,.02],[0],[]),
                         ([.01,.02],[True,0],[]),([.01,.02],[0,0],[0,0])]:
 try:sequences.eligibility(times,runs,.1,broken_intervals=breaks)
 except ValueError:pass
 else:raise AssertionError('Invalid sequence accepted')
""")


if __name__ == '__main__':
    unittest.main()
