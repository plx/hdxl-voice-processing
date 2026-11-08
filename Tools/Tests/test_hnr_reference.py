"""HNR protocol corruption, known-answer equations and retained reference checks."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
DIRECTORY=Path(os.environ.get('HDXL_HNR_REFERENCE_DIRECTORY',ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/HNR'))
PRELUDE="import sys;sys.path.insert(0,'Tools/HNR');import catalog,contract,reference,verify,oracle;from pathlib import Path;"


class HNRReferenceTests(unittest.TestCase):
    def isolated(self,code,*args):
        return subprocess.run([sys.executable,'-c',PRELUDE+code,*map(str,args)],cwd=ROOT,
                              capture_output=True,text=True,timeout=120)

    def assert_probe(self,code,*args):
        result=self.isolated(code,*args)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_direct_sum_correlation_has_closed_form_anchors(self):
        self.assert_probe("""
assert oracle.autocorrelation([1.,0.,-1.,0.],3)==[2.,0.,-1.,0.]
assert oracle.forward_correlation([1.,0.,-1.,0.,1.,0.,-1.,0.],4,4)==[1.,0.,-1.,0.,1.]
assert oracle.forward_correlation([0.]*8,4,4)==[None]*5
assert oracle.autocorrelation([.25]*4,3)==[.25,.1875,.125,.0625]
""")

    def test_sinc_reproduces_integer_data_and_even_symmetry(self):
        self.assert_probe("""
values=[1.,.5,-.25,0.,.1,.2,0.,0.]
for i,value in enumerate(values):
 assert oracle.sinc(values,float(i),700)==value
 assert oracle.sinc(values,float(-i),700)==value
for t in (.2,1.75,3.125,5.6):
 assert abs(oracle.sinc(values,t,700)-oracle.sinc(values,-t,700))<1e-14
for values,position,depth in [([],0.,3),([1.],1.,3),([1.,0.],.5,0)]:
 try: oracle.sinc(values,position,depth)
 except ValueError: pass
 else: raise AssertionError('Invalid interpolation accepted')
""")

    def test_peak_resolution_and_flat_impulse_proof_are_not_name_exceptions(self):
        self.assert_probe("""
import copy,math
from degeneracy import impulse_plateau
assert oracle.peak_kind(.4,.5,.5)=='resolvedPeak' # half-grid ties remain eligible
assert oracle.peak_kind(.5,.5,.4)=='notLocalMaximum'
assert oracle.peak_kind(.5,math.nextafter(.5,1.),.5)=='numericallyFlatPeak'
assert oracle.peak_kind(-.2,-.1,-.2)=='notLocalMaximum'
assert oracle.peak_kind(0.,None,0.)=='undefined'
c=next(c for c in catalog.cases() if c['name']=='impulse-cc-float64')
for gain in (1.,-1.,.5,.1,.01,.3):
 c['source']['gain']=gain;samples=catalog.source_samples(c);result=oracle.frame(samples,c['profile'],12)
 proof=impulse_plateau(samples,c['profile'],result)
 assert proof is not None and result['rawReferenceDB']==-200.
 assert (proof['exactCorrelationNumerator'],proof['exactCorrelationDenominator'])==(53,90791)
 bad=samples.copy();bad[0]=1e-12
 assert impulse_plateau(bad,c['profile'],result) is None
 bad_result=copy.deepcopy(result);bad_result['correlation'][2]+=.001
 assert impulse_plateau(samples,c['profile'],bad_result) is None
 bad_result=copy.deepcopy(result);bad_result['computedMaximumLag']-=1
 assert impulse_plateau(samples,c['profile'],bad_result) is None
 bad_result=copy.deepcopy(result);bad_result['selected']=0
 assert impulse_plateau(samples,c['profile'],bad_result) is None
""")

    def test_fused_frame_grid_preserves_reference_sample_boundary(self):
        self.assert_probe("""
import math
p=catalog.profile('ac',rate=44100,floor=60.,hop=.005)
shape=catalog.geometry(p,11466);first=shape['firstCenterSeconds'];index=22
fused=math.fma(float(index),p['hopSeconds'],first)
separate=first+index*p['hopSeconds'];dx=1/p['sampleRate']
assert fused==.18500000000000003 and separate==.185
assert math.floor(1+(fused-.5*dx)/dx)==8159
assert math.floor(1+(separate-.5*dx)/dx)==8158
""")

    def test_zero_limit_and_unavailable_are_not_interchangeable(self):
        self.assert_probe("""
assert contract.reference_state(0.)=={'status':'finite','valueDB':0.,'periodicity':.5,'noiseFraction':.5}
assert contract.reference_state(-200.)['valueDB'] is None
assert contract.reference_state(150.)['status']=='upperReportingLimit'
assert contract.reference_state(-150.)['status']=='lowerReportingLimit'
assert contract.reference_state(149.)['status']=='finite'
for value in (float('nan'),float('inf'),True,-199.,151.):
 try: contract.reference_state(value)
 except ValueError: pass
 else: raise AssertionError('Invalid raw HNR accepted')
assert contract.comparison_fraction(20.00001,20.)<1
assert contract.comparison_fraction(20.001,20.)>1
assert contract.comparison_fraction(114.03286,114.0331)<1
assert contract.comparison_fraction(90.,114.0331)>1
""")

    def test_profiles_reject_unknown_conventions_and_boolean_numbers(self):
        self.assert_probe("""
p=catalog.profile('ac');catalog.validate_profile(p)
for changed in [{**p,'schemaVersion':True},{**p,'extra':1},{**p,'sampleRate':16000.},
                {**p,'silenceThreshold':False},{**p,'window':'praatGaussian2'},
                {**p,'interpolation':'sinc70'},{**p,'method':'ac-cc'}]:
 try:catalog.validate_profile(changed)
 except ValueError:pass
 else:raise AssertionError('Invalid profile accepted')
assert catalog.geometry(p,1919)['frameCount']==0
assert catalog.geometry(p,1920)['frameCount']==1
assert catalog.geometry(catalog.profile('cc'),8000)['frameCount']==43
""")

    def test_protocol_rejects_missing_duplicate_nonfinite_units_and_time(self):
        self.assert_probe("""
p=catalog.profile('ac')
good='begin\\thnr-reference-v1\\ninput\\t16000\\t1920\\nsettings\\tac\\t0.01\\t75\\t0.1\\t4.5\\naxes\\t1\\t0.06\\t0.01\\nmean\\tdecibelsRatio\\t0\\nframe\\t1\\t0.06\\t0\\nend\\thnr-reference-v1\\n'
assert reference.parse(good,p,1920)['frames'][0]['status']=='finite'
bad=[good[:-8],good.replace('frame\\t1','frame\\t2'),good.replace('decibelsRatio','dBFS'),
 good.replace('frame\\t1\\t0.06\\t0','frame\\t1\\t0.061\\t0'),
 good.replace('frame\\t1\\t0.06\\t0','frame\\t1\\t0.06\\tnan'),
 good.replace('frame\\t1\\t0.06\\t0','frame\\t1\\t0.06\\t--undefined--'),
 good.replace('frame\\t1\\t0.06\\t0','frame\\t1\\t0.06\\t-151'),
 good.replace('frame\\t1\\t0.06\\t0\\n','frame\\t1\\t0.06\\t0\\n'*2),
 good.replace('settings\\tac','settings\\tcc'),good.replace('mean\\tdecibelsRatio\\t0','mean\\tdecibelsRatio\\t1')]
for raw in bad:
 try: reference.parse(raw,p,1920)
 except ValueError: pass
 else: raise AssertionError('Malformed protocol accepted')
silent=good.replace('mean\\tdecibelsRatio\\t0','mean\\tdecibelsRatio\\t--undefined--').replace('frame\\t1\\t0.06\\t0','frame\\t1\\t0.06\\t-200')
assert reference.parse(silent,p,1920)['availableFrameCount']==0
""")

    def test_catalog_reference_and_cross_case_invariants(self):
        self.assert_probe("r=verify.verify(Path(sys.argv[1]));assert r['cases']==180 and r['frames']>3000 and not r['partial']",DIRECTORY)

    def test_rehashed_record_corruption_is_rejected_by_raw_reconstruction(self):
        self.assert_probe("""
import copy
directory=Path(sys.argv[1]);c=next(c for c in catalog.cases() if c['name']=='noisy-0.05-ac-float64')
name=c['name'];record=reference.load_json(directory/(name+'.json'));encoded=(directory/(name+'.wav')).read_bytes();raw=(directory/(name+'.raw.txt')).read_text();lock=reference.load_json(reference.LOCK)
verify.verify_record(record,c,encoded,raw,lock)
mutations=[lambda r:r['data']['frames'][0].update(valueDB=0),
 lambda r:r['input'].update(normalizedFloat64LESHA256='0'*64),
 lambda r:r.update(referenceIdentity='0'*64),
 lambda r:r['data']['frames'][0].update(status='unavailable'),
 lambda r:r['comparisonPolicy'].update(moderateRangeAbsoluteDB=10.)]
for change in mutations:
 bad=copy.deepcopy(record);change(bad)
 try:verify.verify_record(bad,c,encoded,raw,lock)
 except ValueError:pass
 else:raise AssertionError('Changed semantic record accepted')
try:verify.verify_record(record,c,encoded[:-1],raw,lock)
except ValueError:pass
else:raise AssertionError('Changed PCM accepted')
""",DIRECTORY)

    def test_generation_cannot_replace_committed_or_existing_candidates(self):
        self.assert_probe("""
for path in (Path('Tests/HDXLVoiceProcessingTests/Fixtures/HNR'),Path('.build')):
 try:reference.generate(path)
 except ValueError as e:assert 'absent candidate directory under .build' in str(e)
 else:raise AssertionError('Unsafe generation path accepted')
""")


if __name__=='__main__':unittest.main()
