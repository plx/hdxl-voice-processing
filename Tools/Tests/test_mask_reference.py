"""Offline mask protocol and provenance tests; no reference executable is launched."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GOLDEN = ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/Masks'
PRELUDE = "import sys; sys.path.insert(0, 'Tools/Masks'); import verify, reference, oracle; from pathlib import Path; "


class MaskReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='mask-corruption-')
        cls.directory = Path(cls.temporary.name)/'candidate'
        shutil.copytree(GOLDEN, cls.directory)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def isolated(self, code, *arguments):
        return subprocess.run([sys.executable, '-c', PRELUDE+code, *map(str,arguments)],
                              cwd=ROOT, capture_output=True, text=True, timeout=120)

    def test_complete_offline_catalog(self):
        result = self.isolated("assert verify.verify(Path(sys.argv[1])) == {'cases':35,'frames':5088,'anomalies':3,'files':55}", GOLDEN)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_matrix_parser_rejects_nonfinite_wrong_shapes_and_trailing_data(self):
        valid = 'File type = "ooTextFile"\nObject class = "Matrix 2"\n\n0\n1\n3\n0.1\n0.1\n0.5\n1.5\n1\n1\n1\n0\n1\n2\n'
        code = "import json; good=json.loads(sys.argv[1]); assert reference.matrix(good.encode(),'Matrix')[1] == [[0,1,2]]; "
        code += "\nfor raw in [good+'3\\n',good[:-2],good.replace('\\n3\\n','\\n2.5\\n',1),good.replace('\\n2\\n','\\nnan\\n'),good.replace('Matrix 2','Spectrogram 2')]:\n try: reference.matrix(raw.encode(),'Matrix')\n except ValueError: pass\n else: raise AssertionError('malformed matrix accepted')\n"
        result = self.isolated(code, json.dumps(valid))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_textgrid_parser_rejects_overlap_holes_and_unknown_labels(self):
        valid = 'File type = "ooTextFile"\nObject class = "TextGrid"\n\n0\n1\n<exists>\n1\n"IntervalTier"\n"VAD"\n0\n1\n2\n0\n0.5\n"speech"\n0.5\n1\n"non-speech"\n'
        code = "import json; good=json.loads(sys.argv[1]); assert len(reference.textgrid(good.encode())[0]['intervals'])==2; "
        code += "\nfor raw in [good+'0\\n',good.replace('non-speech','phonation'),good.replace('\\n0.5\\n1\\n','\\n0.4\\n1\\n'),good.replace('\\n0.5\\n1\\n','\\n0.6\\n1\\n')]:\n try: reference.textgrid(raw.encode())\n except ValueError: pass\n else: raise AssertionError('malformed tier accepted')\n"
        result = self.isolated(code, json.dumps(valid))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_temporal_oracle_has_closed_form_scale_and_zero_anchors(self):
        code = "import math; axes={'frequencyStep':1,'hop':1,'minimumTime':-.5,'maximumTime':2.5,'firstCenter':0}; "
        code += "p={'minimumFrequencyHz':2,'maximumFrequencyHz':3,'longWindowSeconds':2,'shortWindowSeconds':1}; "
        code += "rows=[[0,0,0],[1,4,16],[1,4,16]]; actual=oracle.flatness(rows,axes,p); "
        code += "expected=[0,2*math.log10(.8),2*math.log10(.8)]; assert max(abs(a-b) for a,b in zip(actual,expected))<1e-14; "
        code += "assert oracle.flatness([[0,0,0]]*3,axes,p)==[0,0,0]; "
        code += "scaled=oracle.flatness([[v*1e-100 for v in row] for row in rows],axes,p); assert max(abs(a-b) for a,b in zip(actual,scaled))<1e-12"
        result = self.isolated(code)
        self.assertEqual(result.returncode, 0, result.stderr)

    def mutate_record(self, change):
        path = self.directory/'tone-envelope.json'
        manifest_path = self.directory/'manifest.json'
        original, manifest_bytes = path.read_bytes(), manifest_path.read_bytes()
        try:
            record = json.loads(original)
            change(record)
            modified = json.dumps(record).encode()
            path.write_bytes(modified)
            manifest = json.loads(manifest_bytes)
            manifest['cases'][0]['sha256'] = hashlib.sha256(modified).hexdigest()
            manifest_path.write_text(json.dumps(manifest))
            result = self.isolated('verify.verify(Path(sys.argv[1]))', self.directory)
            self.assertNotEqual(result.returncode, 0, 'Semantic mutation survived a repaired file hash')
        finally:
            path.write_bytes(original)
            manifest_path.write_bytes(manifest_bytes)

    def test_profile_input_and_independent_source_identity_are_checked(self):
        for mutation in (
            lambda record: record['profile'].update(flatnessThreshold=-9),
            lambda record: record['input'].update(normalizedFloat64LESHA256='0'*64),
            lambda record: record.update(intensityExpectedSource='native-runtime'),
            lambda record: record.update(independentFlatnessMaximumBudgetFraction=2),
            lambda record: record['tiers'][0]['intervals'][0].update(startSeconds=.001),
        ):
            self.mutate_record(mutation)

    def test_original_pcm_changes_are_detected_without_execution(self):
        path = self.directory/'inputs/tone-envelope.wav'
        original = path.read_bytes()
        try:
            changed = bytearray(original)
            changed[-1] ^= 1
            path.write_bytes(changed)
            result = self.isolated('verify.verify(Path(sys.argv[1]))', self.directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('PCM differs', result.stderr)
        finally:
            path.write_bytes(original)

    def test_reference_timeout_is_not_accepted_as_success(self):
        path = self.directory/'reference-anomalies.json'
        manifest_path = self.directory/'manifest.json'
        original, manifest_bytes = path.read_bytes(), manifest_path.read_bytes()
        try:
            record = json.loads(original)
            record['cases'][1]['receipt']['timedOut'] = False
            modified = json.dumps(record).encode()
            path.write_bytes(modified)
            manifest = json.loads(manifest_bytes)
            manifest['negativeCases']['sha256'] = hashlib.sha256(modified).hexdigest()
            manifest_path.write_text(json.dumps(manifest))
            result = self.isolated('verify.verify(Path(sys.argv[1]))', self.directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Nontermination receipt', result.stderr)
        finally:
            path.write_bytes(original)
            manifest_path.write_bytes(manifest_bytes)

    def test_unexpected_artifacts_fail_inventory(self):
        path = self.directory/'unreviewed.bin'
        try:
            path.write_bytes(b'not a fixture')
            result = self.isolated('verify.verify(Path(sys.argv[1]))', self.directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unexpected or missing fixture', result.stderr)
        finally:
            path.unlink(missing_ok=True)
