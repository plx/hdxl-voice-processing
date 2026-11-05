"""Independent subprocesses keep generic developer-module names isolated."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GOLDEN = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/CPP'
PRELUDE = "import sys; sys.path.insert(0, 'Tools/CPP'); import verify, reference; from pathlib import Path; "


class CPPReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='cpp-corruption-')
        cls.directory = Path(cls.temporary.name) / 'candidate'
        shutil.copytree(GOLDEN, cls.directory)
        cls.manifest = (cls.directory / 'manifest.json').read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_isolated(self, code, *arguments):
        return subprocess.run([sys.executable, '-c', PRELUDE + code, *map(str, arguments)],
                              cwd=ROOT, capture_output=True, text=True, timeout=120)

    def changed_record(self, mutation):
        import hashlib
        path = self.directory / 'straight-background.json'
        original = path.read_bytes()
        try:
            record = json.loads(original)
            mutation(record)
            # Use the same canonical writer: failures must detect changed meaning,
            # not merely formatting or a stale digest in the manifest.
            temporary_json = self.directory / 'mutation.tmp'
            temporary_json.write_text(json.dumps(record))
            result = self.run_isolated(
                'from common import canonical, load_json; Path(sys.argv[2]).write_bytes(canonical(load_json(Path(sys.argv[1])))+b"\\n")',
                temporary_json, path)
            temporary_json.unlink()
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads(self.manifest)
            manifest['cases'][0]['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            (self.directory / 'manifest.json').write_text(json.dumps(manifest))
            result = self.run_isolated('verify.verify(Path(sys.argv[1]))', self.directory)
            self.assertNotEqual(result.returncode, 0, 'Rehashed corruption was accepted')
            self.assertIn('ValueError', result.stderr)
        finally:
            path.write_bytes(original)
            (self.directory / 'manifest.json').write_bytes(self.manifest)

    def test_all_committed_inputs_external_trials_and_independent_oracles(self):
        result = self.run_isolated('import json; print(json.dumps(verify.verify()))')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual((report['cases'], report['profileComparisons'], report['externalTrials'],
                          report['knownReferenceExceptions'], report['knownFailedTrials']),
                         (216, 1414, 2222, 32, 6))

    def test_rehashed_inputs_geometry_policy_and_boolean_schema_are_rejected(self):
        for mutation in [lambda r: r['power'].__setitem__(80, 123),
                         lambda r: r['frameConfiguration'].update(sampleRate=8000),
                         lambda r: r.update(schemaVersion=True),
                         lambda r: r['comparisonPolicy'].update(cppDBAbsolute=1),
                         lambda r: r['referenceToolchain'].update(schemaVersion=True),
                         lambda r: r.update(upstreamUnavailable=True)]:
            self.changed_record(mutation)

    def test_rehashed_fit_diagnostics_seed_and_reference_exceptions_are_checked(self):
        for mutation in [lambda r: r['results'][0]['expected'].update(cppDB=100),
                         lambda r: r['results'][0]['expected']['residuals'].update(rmsDB=1),
                         lambda r: r['results'][0]['effectiveFit'].update(firstBin=0),
                         lambda r: r['results'][4].update(knownReferenceException=False),
                         lambda r: r['results'][4].update(expectedFitSource='pinned-praat-query'),
                         lambda r: r['results'][4]['trials'][0].update(seed=271828)]:
            self.changed_record(mutation)

    def test_manifest_cannot_hide_missing_unapproved_or_extra_cases(self):
        path = self.directory / 'manifest.json'
        try:
            for mutation in [lambda m: m.update(calibrationOnly=True), lambda m: m.update(schemaVersion=True),
                             lambda m: m['cases'].pop(), lambda m: m['theilReferenceExceptions'].pop(),
                             lambda m: m['cases'][0].update(file='../escape.json')]:
                manifest = json.loads(self.manifest)
                mutation(manifest)
                path.write_text(json.dumps(manifest))
                result = self.run_isolated('verify.verify(Path(sys.argv[1]))', self.directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('ValueError', result.stderr)
        finally:
            path.write_bytes(self.manifest)
        extra = self.directory / 'extra.json'
        try:
            extra.write_text('{}')
            self.assertNotEqual(self.run_isolated('verify.verify(Path(sys.argv[1]))', self.directory).returncode, 0)
        finally:
            extra.unlink()

    def test_reference_parser_rejects_extra_or_nonfinite_observations(self):
        good = 'cpp-reference-v1\t0\t20\t12\t32\t0.008\n'
        result = self.run_isolated('assert reference.parse(sys.argv[1])["cppDB"] == 12', good)
        self.assertEqual(result.returncode, 0, result.stderr)
        for bad in [good + good, good.replace('12', 'nan'), good.replace('12', 'inf'),
                    good.replace('12', '--undefined--'), good.replace('v1', 'v2'), good + 'extra\n']:
            self.assertNotEqual(self.run_isolated('reference.parse(sys.argv[1])', bad).returncode, 0)

    def test_generation_cannot_overwrite_goldens_or_write_outside_build(self):
        for destination in [GOLDEN, Path(self.temporary.name) / 'outside-build']:
            result = self.run_isolated('reference.generate(Path(sys.argv[1]))', destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('below .build', result.stderr)

    def test_sanitized_reference_failure_evidence_is_not_an_arbitrary_allowance(self):
        code = '''
import copy
from common import load_json
from cpp_catalog import cases
fixture = load_json(verify.GOLDEN / 'very-large-power.json')
case = next(case for case in cases() if case['name'] == 'very-large-power')
row = fixture['results'][4]
for trial in row['trials']:
    verify.validate_trial(trial, case, row['profile'], trial['seed'])
bad = copy.deepcopy(row['trials'][0])
bad['message'] = bad['message'].replace('median_common.h', 'unrelated.cpp')
bad['normalizedStderrSHA256'] = reference.sha(bad['message'].encode())
try:
    verify.validate_trial(bad, case, row['profile'], bad['seed'])
except ValueError:
    pass
else:
    raise AssertionError('Unrelated failure was accepted')
'''
        result = self.run_isolated(code)
        self.assertEqual(result.returncode, 0, result.stderr)
