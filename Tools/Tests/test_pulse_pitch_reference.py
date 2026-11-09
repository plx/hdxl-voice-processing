"""Separate reference-F0 protocol anchors without launching an estimator."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = r'''
import sys
sys.path.insert(0,'Tools/Pulses')
import pitch_reference
raw='\n'.join([
 'begin\tpulse-f0-reference-v1', 'input\t16000\t320',
 'settings\t0.005\t75\t700\t15\t1\t0.03\t0.45\t0.01\t0.35\t0.14',
 'pitch\t2\t0.005\t0.005\t0\t0.02',
 'f0\t1\t0.005\t200', 'f0\t2\t0.01\t--undefined--',
 'count\t3', 'pulse\t1\t-0.001', 'pulse\t2\t0.004', 'pulse\t3\t0.02',
 'end\tpulse-f0-reference-v1', ''])
def rejects(candidate):
 try: pitch_reference.parse(candidate,16000,320)
 except ValueError: pass
 else: raise AssertionError('Malformed F0 protocol accepted')
'''


class PulsePitchReferenceTests(unittest.TestCase):
    def check(self, code):
        result = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_interior_grid_and_raw_edge_pulses_remain_explicit(self):
        self.check('''
p,t=pitch_reference.parse(raw,16000,320)
assert p==dict(domainEndSeconds=.02,firstCenterSeconds=.005,stepSeconds=.005,
               ceilingHz=700.,frequenciesHz=[200.,0.])
assert t==[-.001,.004,.02]
empty=raw[:raw.index('count\\t')]+'count\\t0\\nend\\tpulse-f0-reference-v1\\n'
assert pitch_reference.parse(empty,16000,320)[1]==[]
''')

    def test_settings_axis_and_f0_corruption_fail(self):
        self.check('''
for old,new in [('16000\\t320','16000\\t319'),('settings\\t0.005','settings\\t0.01'),
                ('75\\t700\\t15','75\\t700\\t16'),('pitch\\t2','pitch\\t3'),
                ('0.005\\t0\\t0.02','0.005\\t0.001\\t0.02'),
                ('f0\\t2\\t0.01','f0\\t2\\t0.011'),('f0\\t2','f0\\t1'),
                ('--undefined--','0'),('\\t200\\n','\\t700\\n'),
                ('\\t200\\n','\\tnan\\n'),('\\t200\\n','\\t-200\\n')]:
 rejects(raw.replace(old,new))
''')

    def test_direct_pulse_coverage_and_finite_locations_fail_closed(self):
        self.check('''
for old,new in [('count\\t3','count\\t03'),('count\\t3','count\\t4'),
                ('pulse\\t2','pulse\\t1'),('pulse\\t3\\t0.02','pulse\\t3\\t0.004'),
                ('pulse\\t1\\t-0.001','pulse\\t1\\t-0.101'),
                ('pulse\\t3\\t0.02','pulse\\t3\\tinf'),
                ('pulse\\t3\\t0.02','pulse\\t3\\t--undefined--'),
                ('end\\tpulse-f0-reference-v1','extra\\nend\\tpulse-f0-reference-v1')]:
 rejects(raw.replace(old,new))
for row in raw.splitlines():
 rejects(raw.replace(row+'\\n','',1))
''')


if __name__ == '__main__':
    unittest.main()
