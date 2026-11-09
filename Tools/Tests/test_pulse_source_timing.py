"""Independent source timing: outward bounds, exact sums and corruption controls."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = '''
import sys,shutil,tempfile,math
from pathlib import Path
sys.path.insert(0,'Tools/Pulses')
import source_timing as s
import source_reference as r
from reference import canonical,digest,load_json
base=Path('Tests/HDXLVoiceProcessingTests/Fixtures/PulseSourceTiming')
'''


class PulseSourceTimingTests(unittest.TestCase):
    def check(self,code):
        process = subprocess.run([sys.executable,'-c',PRELUDE+code],cwd=ROOT,
                                 capture_output=True,text=True,timeout=120)
        self.assertEqual(process.returncode,0,process.stdout+process.stderr)

    def test_outward_arithmetic_encloses_exact_rational_operations_and_fma(self):
        self.check('''
from fractions import Fraction as F
values=[0.,-.5,.1,math.nextafter(.1,0),math.nextafter(.1,1),1e-20,-1e20,3.141592653589793]
for a in values:
 for b in values:
  x,y=s.Interval.point(a),s.Interval.point(b)
  for bound,exact in ((x+y,F(a)+F(b)),(x-y,F(a)-F(b)),(x*y,F(a)*F(b))):
   assert F(bound.low)<=exact<=F(bound.high)
  if b:
   bound=x/y;assert F(bound.low)<=F(a)/F(b)<=F(bound.high)
  bound=x*y+.37;actual=math.fma(a,b,.37)
  assert bound.low<=actual<=bound.high
try:s.Interval(-1,1)/s.Interval(-.1,.1)
except ValueError:pass
else:raise AssertionError('Undefined division accepted')
''')

    def test_exact_integer_correlations_enclose_closed_form_values_and_guard_assumptions(self):
        self.check('''
e=s.Enclosure([1.,.5,.5,1.,0.,1.],4000,500)
for a,b,k,wanted in ((0,1,0,1.),(0,1,2,.8),(4,4,0,0.)):
 bound,peak=e.correlation(a,b,k)
 assert bound.low<=wanted<=bound.high
for values in ([0.]*8,[1.,-1.],[1e-100]*8,[float('nan')]*8):
 try:s.Enclosure(values,4000,500)
 except ValueError:pass
 else:raise AssertionError('Unproved correlation domain accepted')
flat=s.Enclosure([.5]*400,4000,500)
try:flat.match(s.Interval.point(.05),1)
except ValueError:pass
else:raise AssertionError('Unresolved global maximum accepted')
''')

    def test_all_source_certificates_replay_without_external_or_native_execution(self):
        self.check('''
from unittest.mock import patch
with patch('subprocess.run',side_effect=AssertionError('Tracker execution forbidden')):
 assert r.replay(base)==dict(cases=36,sourcePoints=4290,files=38)
for name in ('gaussian-16000-600-float32','jitter-12pct-float64','modulated-float32'):
 record=load_json(base/(name+'.json'))
 assert record['maximumSourceErrorSamples']<=record['budget']['radiusSamples']
 assert record['maximumEnclosureWidthSamples']<1e-6
''')

    def test_rehashed_source_times_intervals_and_budgets_are_recomputed(self):
        self.check('''
with tempfile.TemporaryDirectory(dir='.build',prefix='pulse-source-tamper-') as temporary:
 for change in ('source','interval','budget','input','schema'):
  directory=Path(temporary)/change;shutil.copytree(base,directory)
  name='gaussian-16000-80-float32.json';record=load_json(directory/name)
  if change=='source':record['points'][0]['sourceTimeSeconds']+=.001
  elif change=='interval':record['points'][0]['algorithmTimeSeconds']=[0.,1.]
  elif change=='budget':record['budget']['radiusSamples']*=100
  elif change=='input':record['inputSHA256']='0'*64
  else:record['schemaVersion']=True
  record['fixtureIdentity']=digest(canonical({k:v for k,v in record.items() if k!='fixtureIdentity'}))
  (directory/name).write_bytes(canonical(record))
  manifest=load_json(directory/'manifest.json');manifest['files'][name]=digest((directory/name).read_bytes())
  (directory/'manifest.json').write_bytes(canonical(manifest))
  try:r.replay(directory)
  except ValueError:pass
  else:raise AssertionError('Rehashed certificate corruption accepted: '+change)
''')

    def test_coverage_sources_and_execution_scope_fail_closed(self):
        self.check('''
with tempfile.TemporaryDirectory(dir='.build',prefix='pulse-source-metadata-') as temporary:
 for change in ('schema','order','source','missing','extra','symlink','execution','duration','scope'):
  directory=Path(temporary)/change;shutil.copytree(base,directory)
  manifest=load_json(directory/'manifest.json')
  if change=='schema':manifest['schemaVersion']=True
  elif change=='order':manifest['cases'].reverse()
  elif change=='source':manifest['generatorSources'][next(iter(manifest['generatorSources']))]='0'*64
  elif change=='missing':(directory/'gaussian-16000-80-float32.json').unlink()
  elif change=='extra':(directory/'unexpected').write_text('')
  elif change=='symlink':
   file=directory/'gaussian-16000-80-float32.json';file.unlink();file.symlink_to((base/file.name).resolve())
  else:
   execution=load_json(directory/'execution.json')
   if change=='execution':execution['schemaVersion']=True
   elif change=='duration':execution['trials'][0]['seconds']=False
   else:execution['scope']='native performance'
   (directory/'execution.json').write_bytes(canonical(execution))
  (directory/'manifest.json').write_bytes(canonical(manifest))
  try:r.replay(directory)
  except ValueError:pass
  else:raise AssertionError('Invalid certificate metadata accepted: '+change)
''')


if __name__=='__main__':unittest.main()
