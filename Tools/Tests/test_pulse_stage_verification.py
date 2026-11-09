"""Stage fixture replay and rehashed-corruption controls; no external execution."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = '''
import sys, shutil, tempfile
from pathlib import Path
sys.path.insert(0, 'Tools/Pulses')
import verify_stages
from reference import canonical,digest,load_json
root=Path.cwd()
base=root/'Tests/HDXLVoiceProcessingTests/Fixtures/PulseF0Stages'
temporary=tempfile.TemporaryDirectory(prefix='pulse-stage-controls-',dir=root/'.build')
def copy():
 p=Path(temporary.name)/'mutated'
 if p.exists(): shutil.rmtree(p)
 shutil.copytree(base,p)
 return p
def reject(p):
 try: verify_stages.verify_f0(p)
 except ValueError: pass
 else: raise AssertionError('Corrupt stage accepted')
def rehash(p,name):
 s=load_json(p/'summary.json');s['files'][name]=digest((p/name).read_bytes())
 (p/'summary.json').write_bytes(canonical(s))
'''


class PulseStageVerificationTests(unittest.TestCase):
    def check(self, code):
        result = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_f0_replay_has_complete_exact_query_coverage(self):
        self.check('''
assert verify_stages.verify_f0(base)==dict(cases=10,queries=255,files=40)
''')

    def test_rehashed_query_input_and_derived_answer_corruption_fail(self):
        self.check('''
stem='binary-100-200-300'
for suffix in ('.json','.Pitch','.queries.txt','.raw.txt'):
 p=copy();file=p/(stem+suffix)
 if suffix=='.json':
  record=load_json(file);record['oracle'][2]['external']=999.;file.write_bytes(canonical(record))
 elif suffix=='.Pitch': file.write_bytes(file.read_bytes().replace(b'100.0',b'101.0'))
 elif suffix=='.queries.txt': file.write_text('0.0\\n'+file.read_text())
 else: file.write_bytes(file.read_bytes().replace(b'\\t100\\n',b'\\t101\\n'))
 rehash(p,file.name);reject(p)
''')

    def test_summary_tolerance_coverage_identity_and_execution_fail_closed(self):
        self.check('''
for change in ('tolerance','count','source','case','schema','extra','missing','time','scope'):
 p=copy();s=load_json(p/'summary.json')
 if change=='tolerance': s['comparisonBudgets']['frequencyHz']*=10
 elif change=='count': s['comparisons']-=1
 elif change=='source': s['generatorSources'][next(iter(s['generatorSources']))]='0'*64
 elif change=='case': s['results'].pop()
 elif change=='schema': s['schemaVersion']=True
 elif change=='extra': (p/'extra.json').write_text('{}')
 elif change=='missing':
  name=next(iter(s['files']));(p/name).unlink();del s['files'][name]
 else:
  e=load_json(p/'execution.json')
  if change=='time': e['seconds']=False
  else: e['scope']='native timing'
  (p/'execution.json').write_bytes(canonical(e))
 (p/'summary.json').write_bytes(canonical(s));reject(p)
''')


if __name__ == '__main__':
    unittest.main()
