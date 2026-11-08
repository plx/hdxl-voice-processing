"""Independent history replay and rehashed corruption controls; no native/external run."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = '''
import sys, shutil, tempfile
from pathlib import Path
sys.path.insert(0, 'Tools/Pulses')
import trace_reference
from reference import canonical, digest, load_json
root = Path.cwd()
base = root / 'Tests/HDXLVoiceProcessingTests/Fixtures/PulseHistories'
temporary = tempfile.TemporaryDirectory(prefix='pulse-history-controls-', dir=root / '.build')
stem = 'regular-float32'
def copy():
 p = Path(temporary.name) / 'mutated'
 if p.exists(): shutil.rmtree(p)
 shutil.copytree(base, p)
 return p
def reject(p):
 try: trace_reference.verify_candidates(p)
 except ValueError: pass
 else: raise AssertionError('Corrupt history accepted')
def save(p, name, value):
 (p / name).write_bytes(canonical(value))
def rehash(p, name):
 m = load_json(p / 'manifest.json')
 m['files'][name] = digest((p / name).read_bytes())
 save(p, 'manifest.json', m)
'''


class PulseHistoryVerificationTests(unittest.TestCase):
    def check(self, code):
        result = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_complete_history_replays_without_swift_or_external_reference(self):
        self.check('''
from unittest.mock import patch
with patch.object(trace_reference.reference, 'evaluate', side_effect=AssertionError('External execution forbidden')):
 assert trace_reference.verify_candidates(base) == dict(cases=50, files=200, rawPoints=1434,
  attempts=1586, eligiblePeriods=1088, eligiblePairs=958, availableAmplitudes=890)
''')

    def test_rehashed_wave_pitch_and_transcript_changes_fail(self):
        self.check('''
for suffix in ('.wav', '.Pitch', '.raw.txt'):
 p = copy(); file = p / (stem + suffix); original = file.read_bytes()
 if suffix == '.wav': changed = original[:-1] + bytes([original[-1] ^ 1])
 elif suffix == '.Pitch': changed = original.replace(b'500.0', b'501.0')
 else: changed = original.replace(b'\\t500\\n', b'\\t501\\n')
 assert changed != original
 file.write_bytes(changed); rehash(p, file.name); reject(p)
''')

    def test_rehashed_graph_history_and_derived_results_fail(self):
        self.check('''
for change in ('edge', 'attempt', 'period', 'amplitude', 'source', 'comparison', 'schema', 'extra'):
 p = copy(); name = stem + '.json'; record = load_json(p / name)
 if change == 'edge': record['oracle']['rawTrackingEdges'].pop()
 elif change == 'attempt': record['oracle']['attempts'][0]['acceptedByReferenceGates'] = False
 elif change == 'period': record['oracle']['periods'][0]['rejections'] = []
 elif change == 'amplitude': record['oracle']['amplitudes'][2]['rmsAmplitude'] = 0
 elif change == 'source': record['oracle']['knownSourceLandmarks'][0]['timeSeconds'] += .00001
 elif change == 'comparison': record['comparison']['maximumPositionErrorSamples'] = .25
 elif change == 'schema': record['schemaVersion'] = True
 else: record['unknown'] = 1
 record['fixtureIdentity'] = digest(canonical({k:v for k,v in record.items() if k != 'fixtureIdentity'}))
 save(p, name, record); rehash(p, name); reject(p)
''')

    def test_manifest_coverage_identity_and_policy_fail_closed(self):
        self.check('''
for change in ('schema', 'extra', 'source', 'policy', 'order', 'duplicate', 'case', 'missing', 'hash', 'kind'):
 p = copy(); m = load_json(p / 'manifest.json')
 if change == 'schema': m['schemaVersion'] = True
 elif change == 'extra': m['unknown'] = 1
 elif change == 'source': m['generatorSources'][next(iter(m['generatorSources']))] = '0' * 64
 elif change == 'policy': m['comparison']['timeSamples'] *= 10
 elif change == 'order': m['catalog'].reverse()
 elif change == 'duplicate': m['catalog'].append(m['catalog'][0])
 elif change == 'case': m['catalog'][0]['name'] = '../escape'
 elif change == 'missing': del m['files'][stem + '.wav']
 elif change == 'hash': m['files'][stem + '.wav'] = '0' * 64
 else: m = list(m)
 save(p, 'manifest.json', m); reject(p)
''')

    def test_artifact_paths_and_execution_cannot_hide_incomplete_evidence(self):
        self.check('''
for change in ('extra', 'missing', 'symlink', 'duplicateJSON', 'schema', 'time', 'scope', 'trial', 'kind'):
 p = copy()
 if change == 'extra': (p / 'unexpected.json').write_text('{}')
 elif change == 'missing': (p / (stem + '.Pitch')).unlink()
 elif change == 'symlink':
  file = p / (stem + '.wav'); file.unlink(); file.symlink_to(base / file.name)
 elif change == 'duplicateJSON':
  file = p / 'manifest.json'
  file.write_bytes(file.read_bytes().replace(b'"schemaVersion":1', b'"schemaVersion":1,"schemaVersion":1'))
 else:
  e = load_json(p / 'execution.json')
  if change == 'schema': e['schemaVersion'] = True
  elif change == 'time': e['trials'][0]['seconds'] = False
  elif change == 'scope': e['scope'] = 'native throughput'
  elif change == 'trial': e['trials'][0] = []
  else: e = list(e)
  save(p, 'execution.json', e)
 reject(p)
''')


if __name__ == '__main__':
    unittest.main()
