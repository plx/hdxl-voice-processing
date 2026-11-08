"""Estimated-F0 integration is independent from fixed-F0 tracker conformance."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = '''
import sys, shutil, tempfile
from pathlib import Path
sys.path.insert(0, 'Tools/Pulses')
import yin_reference as y
from reference import canonical, digest, load_json
root = Path.cwd()
base = root / 'Tests/HDXLVoiceProcessingTests/Fixtures/PulseYIN'
temporary = tempfile.TemporaryDirectory(prefix='pulse-yin-controls-', dir=root / '.build')
def copy():
 p = Path(temporary.name) / 'mutated'
 if p.exists(): shutil.rmtree(p)
 shutil.copytree(base, p)
 return p
def save(p, name, value): (p / name).write_bytes(canonical(value))
def rehash(p, name):
 m = load_json(p / 'manifest.json'); m['files'][name] = digest((p / name).read_bytes())
 save(p, 'manifest.json', m)
def reject(p):
 try: y.verify_candidates(p)
 except ValueError: pass
 else: raise AssertionError('Corrupt integration evidence accepted')
'''


class PulseYINIntegrationTests(unittest.TestCase):
    def check(self, code):
        process = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                 capture_output=True, text=True, timeout=120)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_existing_yin_equations_reproduce_all_integration_inputs_without_external_execution(self):
        self.check('''
from unittest.mock import patch
with patch.object(y.reference, 'evaluate', side_effect=AssertionError('External execution forbidden')):
 assert y.verify_candidates(base) == dict(cases=16, files=64, fullYINFrames=152, rawPulses=175)
for name in ('silence', 'constant', 'float32-breathy'):
 source = y.input_case(name)
 assert source['frames'] and all(v == 0 for v in source['pitch']['frequenciesHz'])
 assert source['pitch']['firstCenterSeconds'] > source['pitch']['stepSeconds'] / 2
 assert all(f['observedSampleCount'] == source['frames'][0]['observedSampleCount'] for f in source['frames'])
''')

    def test_rehashed_upstream_selection_and_pulse_answers_are_recomputed(self):
        self.check('''
for change in ('upstream', 'frame', 'pulse', 'policy', 'wave', 'pitch'):
 p = copy(); name = 'tone-80.json'; r = load_json(p / name)
 if change == 'upstream': r['source']['pitch']['frequenciesHz'][0] += 1
 elif change == 'frame': r['source']['frames'][0]['status'] = 'unvoiced'
 elif change == 'pulse': r['external']['data']['pulseTimesSeconds'][0] += .001
 elif change == 'policy': r['policy']['otherStatuses'] = 'force-voiced'
 elif change == 'wave':
  name = 'tone-80.wav'; raw = (p / name).read_bytes(); (p / name).write_bytes(raw[:-1] + bytes([raw[-1] ^ 1]))
 else:
  name = 'tone-80.Pitch'; (p / name).write_bytes((p / name).read_bytes() + b'0\\n')
 if name.endswith('.json'):
  r['fixtureIdentity'] = digest(canonical({k:v for k,v in r.items() if k != 'fixtureIdentity'}))
  save(p, name, r)
 rehash(p, name); reject(p)
''')

    def test_catalog_policy_sources_and_file_coverage_cannot_be_changed(self):
        self.check('''
for change in ('schema', 'order', 'policy', 'source', 'tolerance', 'hash', 'extra', 'missing', 'symlink'):
 p = copy(); m = load_json(p / 'manifest.json')
 if change == 'schema': m['schemaVersion'] = True
 elif change == 'order': m['cases'].reverse()
 elif change == 'policy': m['policy']['frameSelection'] = 'include-partial'
 elif change == 'source': m['generatorSources'][next(iter(m['generatorSources']))] = '0' * 64
 elif change == 'tolerance': m['comparison']['rawPulseTimeSamples'] *= 10
 elif change == 'hash': m['files']['tone-80.wav'] = '0' * 64
 elif change == 'extra': (p / 'unexpected').write_text('')
 elif change == 'missing': (p / 'tone-80.Pitch').unlink()
 else:
  file = p / 'tone-80.wav'; file.unlink(); file.symlink_to(base / file.name)
 save(p, 'manifest.json', m); reject(p)
''')


if __name__ == '__main__':
    unittest.main()
