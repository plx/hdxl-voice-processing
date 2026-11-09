"""Strict boundary-query protocol controls, independent of the external executable."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = r'''
import sys
sys.path.insert(0,'Tools/Pulses')
import f0_probe
queries=[-.001,0.,.005,.01]
raw='\n'.join(['begin\tpulse-f0-boundaries-v1','count\t4',
 'query\t1\t-0.001\t--undefined--','query\t2\t0\t100',
 'query\t3\t0.005\t150','query\t4\t0.01\t--undefined--',
 'end\tpulse-f0-boundaries-v1',''])
def rejects(raw):
 try:f0_probe.parse(raw,queries)
 except ValueError:pass
 else:raise AssertionError('Malformed boundary transcript accepted')
'''


class PulseF0ProbeTests(unittest.TestCase):
    def check(self, code):
        result = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_explicit_undefined_and_exact_query_identity(self):
        self.check('''
assert f0_probe.parse(raw,queries)==[None,100.,150.,None]
assert f0_probe.encode_queries(queries)==b'-0.001\\n0.0\\n0.005\\n0.01\\n'
''')

    def test_missing_reordered_and_extra_rows_fail(self):
        self.check('''
for line in raw.splitlines():rejects(raw.replace(line+'\\n','',1))
for old,new in [('count\\t4','count\\t3'),('query\\t2','query\\t1'),
                ('query\\t3\\t0.005','query\\t3\\t0.006'),
                ('query\\t3','query\\t03'),
                ('end\\tpulse-f0-boundaries-v1','extra\\nend\\tpulse-f0-boundaries-v1')]:
 rejects(raw.replace(old,new))
''')

    def test_zero_nonfinite_and_impossible_frequency_fail(self):
        self.check('''
for value in ('0','-1','nan','inf','48001','19'):
 rejects(raw.replace('\\t150\\n','\\t'+value+'\\n'))
rejects(raw.replace('query\\t3\\t0.005','query\\t3\\tnan'))
''')

    def test_query_encoding_enforces_finite_bounded_work(self):
        self.check('''
for values in ([],[0.]*1001,[float('nan')],[True],[11.],(0.,)):
 try:f0_probe.encode_queries(values)
 except ValueError:pass
 else:raise AssertionError('Invalid query input accepted')
''')


if __name__ == '__main__':
    unittest.main()
