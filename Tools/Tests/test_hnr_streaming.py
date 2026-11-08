"""Independent causal input, identity, exact grid and reference safety checks."""
import subprocess
import sys
import unittest

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRELUDE = "import sys;sys.path.insert(0,'Tools/HNR');import streaming as s;from pathlib import Path;"


class HNRStreamingReferenceTests(unittest.TestCase):
    def probe(self, code):
        result = subprocess.run([sys.executable, '-c', PRELUDE + code], cwd=ROOT,
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_frozen_causal_identity_input_grid_and_recovery(self):
        self.probe("""
import struct
directory=Path('Tests/HDXLVoiceProcessingTests/Fixtures/HNRCausal')
manifest=s.load_json(directory/'manifest.json')
assert set(manifest['sourceSHA256'])==set(s.SOURCES)
assert all(s.sha((s.ROOT/p).read_bytes())==v for p,v in manifest['sourceSHA256'].items())
assert {p.name for p in directory.iterdir()}==set(manifest['files'])|{'manifest.json'}
assert all(s.sha((directory/p).read_bytes())==v for p,v in manifest['files'].items())
assert len(manifest['catalog'])==12
frames=0
for name in manifest['catalog']:
 r=s.load_json(directory/(name+'.json'));p=r['profile']
 assert p==s.native_profile(p['method'],p['sampleRate'],p['inputPrecision'])
 assert r['profileSHA256']==s.sha(s.canonical(p))
 assert r['generatorIdentity']==s.sha(s.canonical(manifest['sourceSHA256']))
 values=s.samples(p);window,step,count,starts,tail=s.geometry(p)
 assert (directory/(name+'.wav')).read_bytes()==s.pcm_wave(values,p['sampleRate'])
 assert r['input']['normalizedFloat64LESHA256']==s.sha(struct.pack(f'<{count}d',*values))
 assert r['grid']==dict(windowSampleCount=window,stepNumerator=step.numerator,
     stepDenominator=step.denominator,completeFrameCount=len(starts),
     tailStartSample=tail,tailSampleCount=count-tail)
 assert [f['startSample'] for f in r['frames']]==starts
 assert [f['frameIndex'] for f in r['frames']]==list(range(len(starts)))
 assert all(f['sampleCount']==window for f in r['frames'])
 assert all(f['status']=='finite' for f in r['frames'][:3]+r['frames'][-3:])
 assert any(f['status']=='unavailable' for f in r['frames'])
 frames+=len(r['frames'])
assert frames==312
""")

    def test_fractional_hops_and_input_precision_are_explicit(self):
        self.probe("""
from fractions import Fraction
p=s.native_profile('ac',44100,'float64');window,step,count,starts,tail=s.geometry(p)
assert step==Fraction(441,2) and starts[:7]==[0,220,441,661,882,1102,1323]
assert 0<count-tail<window
a=s.samples(p);b=s.samples(s.native_profile('ac',44100,'float32'))
assert a!=b and len(a)==len(b)
assert all(abs(x-y)<=1e-8 for x,y in zip(a,b))
p['hopSeconds']=0.00500453514739229
step=s.geometry(p)[1]
assert step==Fraction(3882595460002611,17592186044416)
assert (1000000*step).__floor__()==220699999
""")

    def test_causal_generation_never_overwrites_existing_or_committed_data(self):
        self.probe("""
for path in (Path('.build'),Path('Tests/HDXLVoiceProcessingTests/Fixtures/HNRCausal')):
 try:s.run(path)
 except ValueError as e:assert 'absent candidate directory under .build' in str(e)
 else:raise AssertionError('Unsafe causal generation accepted')
""")


if __name__ == '__main__':
    unittest.main()
