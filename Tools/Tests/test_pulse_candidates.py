"""Candidate integrity controls, using a hand-written one-sample protocol fixture."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = r'''
import sys, tempfile, shutil
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, 'Tools/Pulses')
import catalog, generate, reference, verify
from reference import canonical, digest, load_json, pcm_wave
name = 'short-1-float64'
case = next(c for c in catalog.cases() if c['name'] == name)
raw = '\n'.join([
 'begin\tpulse-reference-v2', 'input\t16000\t1',
 'periodSettings\t0.0001\t0.02\t1.3',
 'pitch\t1\t0.00003125\t0.0000625\t0\t0.0000625',
 'f0\t1\t0.00003125\t150', 'count\t1', 'pulse\t1\t0.00003125',
 'amplitudes\tinsufficientData\t0', 'end\tpulse-reference-v2', ''])
def fake_evaluate(samples, rate, pitch, *, precision):
 wave, encoded = pcm_wave(samples, rate), reference.encode_pitch(pitch, rate, len(samples))
 record = reference.make_record(wave, encoded, raw, pitch, rate, len(samples), precision,
                                dict(reference.PERIOD_DEFAULTS))
 return record, wave, encoded, raw
temporary = tempfile.TemporaryDirectory(prefix='pulse-verifier-test-', dir=ROOT / '.build')
base = Path(temporary.name) / 'base'
with patch.object(reference, 'evaluate', fake_evaluate):
 generate.generate(base, [name])
def copy_case():
 target = Path(temporary.name) / 'mutated'
 if target.exists(): shutil.rmtree(target)
 shutil.copytree(base, target)
 return target
def save_manifest(path, manifest):
 (path / 'manifest.json').write_bytes(canonical(manifest))
def rehash(path, filename):
 m = load_json(path / 'manifest.json')
 m['files'][filename] = digest((path / filename).read_bytes())
 save_manifest(path, m)
def rejects(path, *, partial=True):
 try: verify.verify(path, allow_partial=partial)
 except ValueError: pass
 else: raise AssertionError('Corrupted/incomplete candidate accepted')
'''


class PulseCandidateTests(unittest.TestCase):
    def check(self, code):
        result = subprocess.run([sys.executable, '-c', 'from pathlib import Path\nROOT=Path.cwd()\n' + PRELUDE + code],
                                cwd=ROOT, capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_partial_catalog_is_explicit(self):
        self.check('''
r = verify.verify(base, allow_partial=True)
assert r['cases'] == 1 and r['pulses'] == 1 and r['amplitudeComparisons'] == 0
assert r['partialCatalog'] is True
rejects(base, partial=False)
''')

    def test_rehashed_wave_pitch_and_raw_corruption_still_fail(self):
        self.check('''
for suffix in ('.wav', '.Pitch', '.raw.txt'):
 p = copy_case(); file = p / (name + suffix)
 data = file.read_bytes()
 if suffix == '.wav': data = data[:-1] + bytes([data[-1] ^ 1])
 elif suffix == '.Pitch': data = data.replace(b'150.0', b'151.0')
 else: data = data.replace(b'\\t150\\n', b'\\t151\\n')
 file.write_bytes(data); rehash(p, file.name); rejects(p)
''')

    def test_rehashed_metadata_and_derived_answers_fail(self):
        self.check('''
for change in ('extra', 'count', 'source', 'amplitude', 'boolean'):
 p = copy_case(); file = p / (name + '.json'); record = load_json(file)
 if change == 'extra': record['unknown'] = 1
 elif change == 'count': record['reference']['data']['pulseCount'] = 0
 elif change == 'source': record['case']['source']['gain'] = .5
 elif change == 'amplitude': record['amplitudeAudit']['comparisons'] = 1
 else: record['schemaVersion'] = True
 body = {k:v for k,v in record.items() if k != 'fixtureIdentity'}
 record['fixtureIdentity'] = digest(canonical(body))
 file.write_bytes(canonical(record)); rehash(p, file.name); rejects(p)
''')

    def test_manifest_coverage_tolerances_and_identities_fail_closed(self):
        self.check('''
for change in ('extra', 'partial', 'boolean', 'duplicate', 'unknownCase', 'order',
               'source', 'tolerance', 'toolchain', 'hash', 'result', 'missing'):
 p = copy_case(); m = load_json(p / 'manifest.json')
 if change == 'extra': m['unknown'] = 1
 elif change == 'partial': m['partialCatalog'] = 1
 elif change == 'boolean': m['schemaVersion'] = True
 elif change == 'duplicate': m['catalog'] *= 2
 elif change == 'unknownCase': m['catalog'][0]['name'] = '../escape'
 elif change == 'order': m['catalog'][0]['source']['gain'] = .5
 elif change == 'source': m['generatorSources'][next(iter(m['generatorSources']))] = '0' * 64
 elif change == 'tolerance': m['amplitudeComparison']['absoluteAmplitude'] *= 2
 elif change == 'toolchain': m['toolchain']['version'] = '0.0.0'
 elif change == 'hash': m['files'][name + '.wav'] = '0' * 64
 elif change == 'result': m['results'][0]['pulses'] = 0
 else: del m['files'][name + '.wav']
 save_manifest(p, m); rejects(p)
''')

    def test_files_and_execution_cannot_hide_missing_or_extra_evidence(self):
        self.check('''
for change in ('extraFile', 'missingFile', 'symlink', 'duplicateJSON', 'timing', 'scope', 'trial'):
 p = copy_case()
 if change == 'extraFile': (p / 'unexpected').write_text('')
 elif change == 'missingFile': (p / (name + '.Pitch')).unlink()
 elif change == 'symlink':
  file = p / (name + '.wav'); file.unlink(); file.symlink_to(base / file.name)
 elif change == 'duplicateJSON':
  file = p / 'manifest.json'
  file.write_bytes(file.read_bytes().replace(b'"schemaVersion":1', b'"schemaVersion":1,"schemaVersion":1'))
 else:
  file = p / 'execution.json'; record = load_json(file)
  if change == 'timing': record['trials'][0]['seconds'] = False
  elif change == 'scope': record['scope'] = 'native throughput'
  else: record['trials'] = []
  file.write_bytes(canonical(record))
 rejects(p)
''')


if __name__ == '__main__':
    unittest.main()
