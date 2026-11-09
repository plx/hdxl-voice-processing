"""Closed-form timing and independent path/coverage invariants before native use."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = '''
import sys,math
sys.path.insert(0,'Tools/Pulses')
import trace_oracle as t
def case(name): return next(c for c in t.cases() if c['name']==name+'-float64')
def trace(name): return t.trace(case(name))
'''


class PulseTraceOracleTests(unittest.TestCase):
    def check(self, code):
        process = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                 capture_output=True, text=True, timeout=60)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_binary_lobe_train_has_closed_form_positions_and_denominators(self):
        self.check('''
for name,offset,periods in [('regular',0.,47),('fractional-seeds',.25,48),('inverted',0.,47),('endpoint-seed',0.,47)]:
 d=trace(name);points=d['landmarks']
 expected=[math.fma(3.+8*i+offset,1/4000,.5/4000) for i in range(50)]
 assert len(points)==50
 assert max(abs(p['timeSeconds']-v)*4000 for p,v in zip(points,expected))<2e-10
 assert sum(not p['rejections'] for p in d['periods'])==periods
 assert sum(not p['rejections'] for p in d['periodPairs'])==periods-1
 assert sum(a['rmsAmplitude'] is not None for a in d['amplitudes'])==periods-1
# Symmetric lobe has three nonzero weighted samples. Its RMS is closed-form.
d=trace('regular');w=math.cos(math.pi/3.2)**4;expected=math.sqrt((1+.5*w)/(1+2*w))
assert all(abs(a['rmsAmplitude']-expected)<2e-12 for a in d['amplitudes'] if a['rmsAmplitude'] is not None)
''')

    def test_silence_missed_steps_and_voicing_never_form_a_spliced_period(self):
        self.check('''
silent=trace('silence');assert len(silent['landmarks'])==1 and not silent['periods']
unvoiced=trace('all-unvoiced');assert not unvoiced['landmarks'] and not unvoiced['attempts']
for name in ('long-zero-gap','unvoiced-gap'):
 d=trace(name);assert d['runCount']>=2
 assert any('trackingFailure' in p['rejections'] for p in d['periods'])
 for p in d['periods']:
  a=d['landmarks'][p['leftPulseIndex']]['timeSeconds'];b=d['landmarks'][p['rightPulseIndex']]['timeSeconds']
  if a<.04 and b>.06: assert p['rejections'] and p['runID'] is None
assert any(not a['acceptedByReferenceGates'] for a in trace('long-zero-gap')['attempts'])
''')

    def test_exclusions_preserve_raw_points_but_split_the_graph(self):
        self.check('''
full=trace('regular')
for name in ('excluded-cycle','adjacent-exclusions'):
 d=trace(name)
 assert [p['timeSeconds'] for p in d['landmarks']]==[p['timeSeconds'] for p in full['landmarks']]
 assert d['runCount']>full['runCount']
 for p in d['periods']:
  a=d['landmarks'][p['leftPulseIndex']]['timeSeconds'];b=d['landmarks'][p['rightPulseIndex']]['timeSeconds']
  for low,high in d['case']['excludedSamples']:
   if a<high/4000 and b>low/4000: assert 'excludedSupport' in p['rejections'] and p['runID'] is None
''')

    def test_period_ranges_and_adjacent_ratios_are_separate_denominators(self):
        self.check('''
for name,reason in [('period-too-short','periodBelowMinimum'),('period-too-long','periodAboveMaximum')]:
 d=trace(name);assert d['periods']
 assert all(reason in p['rejections'] and p['runID'] is None for p in d['periods'])
 assert all(a['rmsAmplitude'] is None for a in d['amplitudes'])
a=trace('alternating-periods');b=trace('alternating-periods-strict')
assert a['periods']==b['periods'] and a['runCount']==b['runCount']
assert sum(not p['rejections'] for p in a['periodPairs'])>30
assert all(p['rejections'] for p in b['periodPairs'])
assert any('adjacentPeriodFactor' in p['rejections'] for p in b['periodPairs'])
''')

    def test_short_fragments_need_complete_support_in_addition_to_pulse_count(self):
        self.check('''
for n in (8,16,24):
 d=trace('short-'+str(n));assert len(d['landmarks'])==n//8
 assert all(p['rejections'] for p in d['periods'])
 assert all(a['rmsAmplitude'] is None for a in d['amplitudes'])
d=trace('short-32');assert sum(not p['rejections'] for p in d['periods'])==1
assert all(a['rmsAmplitude'] is None for a in d['amplitudes'])
d=trace('short-40');assert sum(not p['rejections'] for p in d['periods'])==2
assert sum(a['rmsAmplitude'] is not None for a in d['amplitudes'])==1
''')

    def test_history_encoding_is_canonical_after_json_round_trip(self):
        self.check('''
import json
from reference import canonical
for name in ('short-8','regular','endpoint-seed','long-zero-gap'):
 encoded=canonical(trace(name))
 assert canonical(json.loads(encoded))==encoded
''')


if __name__ == '__main__':
    unittest.main()
