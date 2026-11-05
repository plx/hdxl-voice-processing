"""Offline CPPS corruption and independent mathematical checks; no Praat launched."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GOLDEN = Path(os.environ.get('HDXL_CPPS_REFERENCE_DIRECTORY', ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/CPPS'))
PRELUDE = "import sys; sys.path.insert(0,'Tools/CPPS'); import verify,reference,oracle; from pathlib import Path; "
_spec = importlib.util.spec_from_file_location('cpps_test_contract_json', ROOT/'Tools/Reference/common.py')
_shared = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_shared)


class CPPSReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='cpps-corruption-')
        cls.directory = Path(cls.temporary.name)/'candidate'
        shutil.copytree(GOLDEN, cls.directory)

    @classmethod
    def tearDownClass(cls): cls.temporary.cleanup()

    def isolated(self, code, *arguments):
        return subprocess.run([sys.executable, '-c', PRELUDE+code, *map(str,arguments)],
                              cwd=ROOT, capture_output=True, text=True, timeout=120)

    def test_complete_independent_catalog(self):
        result = self.isolated("assert verify.verify(Path(sys.argv[1])) == 36", GOLDEN)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_triangle_basis_has_hand_derived_impulse_weights(self):
        result = self.isolated("import math; actual=oracle.weights(13,6,5,-25,37); "
            "expected=[(i+3,w/40) for i,w in enumerate([1,7,8,8,8,7,1])]; assert actual==expected; "
            "assert oracle.weights(1,0,25,-25,25)==[(0,1.)]; "
            "q=oracle.weights(513,256,10,0,512); assert q==[(i+251,w/10) for i,w in enumerate([.5]+[1]*9+[.5])]; "
            "edge=oracle.weights(513,0,10,0,512); assert edge[0]==(0,.1); "
            "assert abs(math.fsum(w for _,w in edge)-1)<1e-15")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_protocol_rejects_missing_repeated_nonfinite_and_negative_cells(self):
        lines = ['begin\tcpps-probe-v1', 'axes\t1\t3\t0.05\t0.002\t0.0001', 'cpps\t0']
        for stage in (1,2,3):
            lines.append(f'frame\t{stage}\t1\t0.05\t0\t0\t0\t0.008\t0')
            lines.extend(f'cell\t{stage}\t{row}\t1\t1' for row in (1,2,3))
        lines.append('end\tcpps-probe-v1')
        valid = '\n'.join(lines)+'\n'
        code = "import json; good=json.loads(sys.argv[1]); assert reference.parse(good,True)['cppsDB']==0; "
        code += "\nfor bad in [good[:-5],good.replace('cell\\t1\\t1\\t1\\t1\\n',''),good.replace('cell\\t1\\t1\\t1\\t1\\n','cell\\t1\\t1\\t1\\t1\\n'*2),good.replace('cell\\t1\\t1\\t1\\t1','cell\\t1\\t1\\t1\\tnan'),good.replace('cell\\t1\\t1\\t1\\t1','cell\\t1\\t1\\t1\\t-1')]:\n try: reference.parse(bad,True)\n except ValueError: pass\n else: raise AssertionError('malformed reference accepted')\n"
        result = self.isolated(code, json.dumps(valid))
        self.assertEqual(result.returncode, 0, result.stderr)

    def mutate(self, change, name='tilted-pretrend-smoothed'):
        path = self.directory/(name+'.json')
        manifest_path = self.directory/'manifest.json'
        original, manifest_bytes = path.read_bytes(), manifest_path.read_bytes()
        try:
            record = json.loads(original)
            change(record)
            encoded = _shared.canonical(record)
            path.write_bytes(encoded)
            manifest = json.loads(manifest_bytes)
            manifest['files'][path.name] = hashlib.sha256(encoded).hexdigest()
            manifest_path.write_bytes(_shared.canonical(manifest))
            return self.isolated("verify.verify(Path(sys.argv[1]))", self.directory)
        finally:
            path.write_bytes(original)
            manifest_path.write_bytes(manifest_bytes)

    def test_rehashed_matrix_corruption_fails_mathematical_oracle(self):
        result = self.mutate(lambda r: r['data']['matrices']['3'].__setitem__(100, 7.))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Independent basis integration', result.stderr)

    def test_rehashed_wrong_input_axes_metrics_mean_and_availability_fail(self):
        mutations = [
            lambda r: r['input'].__setitem__('encodedSHA256', '0'*64),
            lambda r: r['data']['axes'].__setitem__('firstCenterSeconds', .051),
            lambda r: r['data']['metrics']['3'][0].__setitem__(2, 100.),
            lambda r: r['data'].__setitem__('cppsDB', 100.),
            lambda r: r['data']['matrices']['3'].__setitem__(0, None),
            lambda r: r['comparisonPolicy'].__setitem__('decibelAbsolute', 1.),
        ]
        for change in mutations:
            with self.subTest(change=change):
                result = self.mutate(change)
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_candidates_cannot_overwrite_fixture_tree(self):
        result = self.isolated("reference.generate(Path(sys.argv[1]))", GOLDEN)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('absent candidate directory under .build', result.stderr)


if __name__ == '__main__': unittest.main()
