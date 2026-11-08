"""Closed-form pulse stage anchors; no native implementation or reference launch."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = "import sys,math;sys.path.insert(0,'Tools/Pulses');import stages\n"


class PulseStageTests(unittest.TestCase):
    def check(self, code):
        result = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_identical_antiphase_orthogonal_and_known_dot_products(self):
        self.check('''
x=[1.,0.,-1.,0.,1.,0.,-1.,0.]
for offset,expected in ((4,1.),(2,-1.),(1,0.)):
 r=stages.observed_correlation(x,0,3,offset)
 assert r['correlation']==expected and r['observedPairCount']==4
 assert r['supportStatus']=='varyingSupport'
r=stages.observed_correlation([.2,.4,.1,.3],0,1,2)
assert abs(r['correlation']-7/math.sqrt(50))<1e-15
assert r['candidatePeak']==.3 and r['supportStatus']=='tooFewPairs'
''')

    def test_only_observed_pairs_contribute_and_missing_is_not_silence(self):
        self.check('''
x=[1.,0.,-1.,0.,1.,0.,-1.,0.]
r=stages.observed_correlation(x,-2,1,2)
assert r['observedPairCount']==2 and r['correlation']==1
assert r['anchorFirstObservedIndex']==0 and r['anchorLastObservedIndex']==1
r=stages.observed_correlation(x,0,3,20)
assert r['observedPairCount']==0 and r['supportStatus']=='noObservedPairs'
assert r['anchorFirstObservedIndex'] is None and r['candidatePeak']==0
r=stages.observed_correlation([0.]*8,0,3,4)
assert r['correlation']==0 and r['supportStatus']=='silent'
r=stages.observed_correlation([.3]*8,0,3,4)
assert r['correlation']==1 and r['supportStatus']=='constantSupport'
''')

    def test_tiny_signal_energy_and_precision_remain_explicit(self):
        self.check('''
from decimal import Decimal
x=[1e-200,0.,-1e-200,0.]*2
r=stages.observed_correlation(x,0,3,4)
assert r['correlation']==1 and r['supportStatus']=='varyingSupport'
assert Decimal(r['exactInputEnergyDecimal']['anchor'])>0
f=stages.observed_correlation(x,0,3,4,precision='float32')
assert f['supportStatus']=='silent'
for gain in (-1.,.01):
 r=stages.observed_correlation([v*gain for v in [.2,.4,.1,.3]],0,1,2)
 assert abs(r['correlation']-7/math.sqrt(50))<1e-15
''')

    def test_quadratic_vertex_has_independent_polynomial_answer(self):
        self.check('''
# y=4+x-2*x*x has its maximum at x=1/4 with y=33/8.
r=stages.quadratic_vertex(1.,4.,3.)
assert r==dict(status='maximum',offsetSamples=.25,value=4.125,curvature=4.)
r=stages.quadratic_vertex(-1.,-4.,-3.)
assert r==dict(status='minimum',offsetSamples=.25,value=-4.125,curvature=-4.)
assert stages.quadratic_vertex(1.,1.,1.)['status']=='flat'
assert stages.quadratic_vertex(1.,2.,3.)['status']=='notLocalExtremum'
assert stages.quadratic_vertex(1.,4.,4.)['offsetSamples']==.5
''')

    def test_sample_index_ties_are_toward_positive_infinity(self):
        self.check('''
for time,low,high,nearest in [(0.,-1,0,0),(-1.,-2,-1,-1),(.5,0,0,0),
                              (1.,0,1,1),(1.25,0,1,1),(1.5,1,1,1)]:
 r=stages.sampled_indices(time,.5,1.)
 assert (r['low'],r['high'],r['nearest'])==(low,high,nearest)
''')

    def test_correlation_table_selection_and_right_neighbor_amplitude_are_explicit(self):
        self.check('''
def curve(values):
 return [dict(candidateFirstIndex=i+10,correlation=x,candidatePeak=.1*(i+1)) for i,x in enumerate(values)]
r=stages.select_correlation_peak(curve([.1,.25,1.,.75,.2]))
assert r['candidateFirstIndex']==12
assert r['offsetSamples']==.25 and r['interpolatedCorrelation']==1.03125
assert r['amplitudeGateCandidateFirstIndex']==13 and r['amplitudeGatePeak']==.4
# Equal local maxima keep the earliest; the final lag cannot be a center.
r=stages.select_correlation_peak(curve([.5,.1,.5,.1]))
assert r['candidateFirstIndex']==10
assert stages.select_correlation_peak(curve([.1,.2,.3]))['status']=='noLocalMaximum'
r=stages.select_correlation_peak(curve([-1.,-.9]))
assert r['syntheticPrecedingCandidate'] and r['candidateFirstIndex']==9
# The correlation sentinels do not invent observed PCM.
r=stages.select_correlation_peak(stages.correlation_curve([0.]*8,0,3,2,4))
assert r['sampledCorrelation']==0 and r['amplitudeGatePeak']==0
''')

    def test_f0_interpolation_stops_at_unvoiced_nearest_frame_and_grid_edges(self):
        self.check('''
p=dict(domainEndSeconds=.1,firstCenterSeconds=.025,stepSeconds=.025,
       ceilingHz=900.,frequenciesHz=[100.,200.,0.])
for t,wanted in [(0,None),(.0124,None),(.0125,100),(.025,100),(.03125,125),
                 (.0375,150),(.05,200),(.05625,200),(.0625,None),(.1,None),(.101,None)]:
 r=stages.sampled_f0(p,t,4000,400)
 assert r==wanted,(t,r,wanted)
p['frequenciesHz'][-1]=300.
assert stages.sampled_f0(p,.0874,4000,400)==300.
# Decimal 0.0875 is just inside this binary64 grid's last half-frame.
assert stages.sampled_f0(p,.0875,4000,400)==300.
assert stages.sampled_f0(p,.0876,4000,400) is None
p=dict(domainEndSeconds=.125,firstCenterSeconds=.03125,stepSeconds=.03125,
       ceilingHz=900.,frequenciesHz=[100.,200.,300.])
assert stages.sampled_f0(p,.109375,4000,500) is None
''')

    def test_gaussian_interpolation_symmetry_and_closed_form_bias(self):
        self.check('''
for sigma in (1.6,3.2,6.4,12.):
 assert abs(stages.gaussian_parabolic_bias(sigma,0.)['signedBiasSamples'])<1e-70
 for phase in (.1,1/3,.5):
  a=stages.gaussian_parabolic_bias(sigma,phase)
  b=stages.gaussian_parabolic_bias(sigma,-phase)
  assert a['signedBiasSamples']==-b['signedBiasSamples']
  assert abs(a['signedBiasSamples'])<.011
r=stages.gaussian_parabolic_bias(1.6,-1/3)
assert abs(r['signedBiasSamples']-.00908597136335995)<1e-15
''')

    def test_nonfinite_unbounded_and_invalid_stage_inputs_fail(self):
        self.check('''
calls=[lambda:stages.observed_correlation([],0,1,2),
 lambda:stages.observed_correlation([1.],True,1,2),
 lambda:stages.observed_correlation([1.],0,5000,2),
 lambda:stages.observed_correlation([1.],0,1,999999),
 lambda:stages.observed_correlation([float('nan')],0,0,0),
 lambda:stages.observed_correlation([1.],0,0,0,precision='double'),
 lambda:stages.quadratic_vertex(0,float('inf'),0),
 lambda:stages.sampled_indices(0,.5,0),
 lambda:stages.sampled_indices(1e308,.5,.001),
 lambda:stages.gaussian_parabolic_bias(.1,0),
 lambda:stages.gaussian_parabolic_bias(2.,.6)]
for call in calls:
 try:call()
 except ValueError:pass
 else:raise AssertionError('Invalid stage input accepted')
''')


if __name__ == '__main__':
    unittest.main()
