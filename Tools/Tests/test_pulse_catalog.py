"""Known source phase, modulation, quantization and F0-grid anchors."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = "import sys,math,struct;sys.path.insert(0,'Tools/Pulses');import catalog\nC={c['name']:c for c in catalog.cases()}\n"


class PulseCatalogTests(unittest.TestCase):
    def check(self, code):
        result = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_catalog_is_bounded_and_separates_supplied_and_reference_f0(self):
        self.check('''
assert len(C) == 110
assert sum(c['inputPrecision']=='float32' for c in C.values()) == 55
assert sum(c['pitchSource']=='praatRawCC' for c in C.values()) == 16
assert {c['sampleRate'] for c in C.values()} == {16000,44100,48000}
for c in C.values():
 if c['pitchSource']=='suppliedContour':
  p=catalog.supplied_pitch(c)
  assert p['domainEndSeconds']==c['sampleCount']*(1/c['sampleRate'])
  assert 0 < p['firstCenterSeconds'] <= p['domainEndSeconds']
  assert math.fma(len(p['frequenciesHz'])-1,p['stepSeconds'],p['firstCenterSeconds']) <= p['domainEndSeconds']
''')

    def test_gaussian_phase_chirp_and_jitter_are_known_independently(self):
        self.check('''
x,landmarks=catalog.source(C['gaussian-16000-150-float64'])
assert len(x)==8000 and len(landmarks)==75
assert landmarks[0]['timeSeconds']==.37/150
for a,b in zip(landmarks,landmarks[1:]):
 assert math.isclose(b['timeSeconds']-a['timeSeconds'],1/150,abs_tol=1e-15)
for name,hz,slope in [('rising-f0',80,1040),('falling-f0',600,-1040)]:
 _,points=catalog.source(C[name+'-float64'])
 for i,p in enumerate(points):
  t=p['timeSeconds']; assert abs(hz*t+.5*slope*t*t-(i+.37)) < 1e-12
_,points=catalog.source(C['jitter-12pct-float64'])
for i,(a,b) in enumerate(zip(points,points[1:])):
 expected=(1+.12*(-1,.5,1,-.5,0)[i%5])/150
 assert math.isclose(b['timeSeconds']-a['timeSeconds'],expected,abs_tol=1e-15)
''')

    def test_amplitude_modulation_missing_cycles_and_polarity_are_explicit(self):
        self.check('''
x,_=catalog.source(C['gaussian-16000-150-float64'])
y,_=catalog.source(C['inverted-float64'])
assert y==[-v for v in x]
_,points=catalog.source(C['modulated-float64'])
assert all(math.isclose(p['amplitude'],[.6/1.4,.6,.6/1.4,.6*.6/1.4][i%4],abs_tol=1e-14)
           for i,p in enumerate(points))
_,points=catalog.source(C['alternating-float64'])
assert all(p['amplitude']==(.12 if i%2 else .6) for i,p in enumerate(points))
_,points=catalog.source(C['missing-cycles-float64'])
assert [i+1 for i,p in enumerate(points) if not p['rendered']]==list(range(7,76,7))
for name in ('gaussian-16000-150','rising-f0','filtered','noisy-high'):
 x,_=catalog.source(C[name+'-float64']); y,_=catalog.source(C[name+'-float32'])
 assert y==list(struct.unpack('<%df'%len(x),struct.pack('<%df'%len(x),*x)))
''')

    def test_explicit_unvoiced_frames_and_wrong_f0_remain_separate_from_pcm(self):
        self.check('''
x,_=catalog.source(C['gaussian-16000-150-float64'])
for name in ('all-unvoiced','unvoiced-gap','wrong-double-f0','wrong-half-f0'):
 y,_=catalog.source(C[name+'-float64']); assert x==y
assert set(catalog.supplied_pitch(C['all-unvoiced-float64'])['frequenciesHz'])=={0.}
p=catalog.supplied_pitch(C['unvoiced-gap-float64'])
assert p['frequenciesHz']==[150.]*40+[0.]*20+[150.]*40
assert set(catalog.supplied_pitch(C['wrong-double-f0-float64'])['frequenciesHz'])=={300.}
assert set(catalog.supplied_pitch(C['wrong-half-f0-float64'])['frequenciesHz'])=={75.}
''')


if __name__ == '__main__':
    unittest.main()
