"""Corruption controls for machine-readable HNR comparison evidence, not DSP goldens."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import subprocess
import unittest

ROOT=Path(__file__).resolve().parents[2]
if __name__ == "__main__":
    sys.path.insert(0,str(ROOT/'Tools/HNR'))
    SPEC=importlib.util.spec_from_file_location('hnr_native_audit',ROOT/'Tools/HNR/native_audit.py')
    audit=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(audit)
    EXTERNAL=ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/HNR'
    CAUSAL=ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/HNRCausal'


    class HNRNativeAuditTests(unittest.TestCase):
        @classmethod
        def setUpClass(cls):
            # Synthetic exact-agreement receipt, using actual frozen case geometry.
            # The six special rows retain genuine one-impulse proof conditions; no
            # synthetic timing or error values are presented as measured evidence.
            rows=[]
            for case in audit.cases():
                name=case['name']; reference=audit.load_json(EXTERNAL/(name+'.json'))
                profile=audit.profile(case['profile']); identity=audit.identity(profile)
                for index,frame in enumerate(reference['data']['frames']):
                    status=frame['status']
                    row=dict(name=name,inputSHA256=reference['input']['encodedSHA256'],
                        configuration=profile,profileIdentity=identity,frameIndex=index,
                        expectedCenterSeconds=frame['centerSeconds'],actualCenterSeconds=frame['centerSeconds'],
                        expectedStatus=status,actualStatus=status,expectedDB=frame['valueDB'],actualDB=frame['valueDB'],
                        actualDecibelStatus=None if status=='unavailable' else status,budgetFraction=0.)
                    if 'impulse' in name and profile['method']=='cc' and index==12 and status=='finite':
                        samples=audit.source_samples(case)
                        row.update(actualStatus='unavailable',actualDB=None,actualDecibelStatus=None,budgetFraction=None,
                            proof=dict(definition='singleImpulseFlatCCLagCurve',impulseIndex=next(i for i,v in enumerate(samples) if v!=0),
                                meanSamples=426,windowSamples=958,comparedLagCount=214,
                                expectedCorrelation=53/90791,maximumCurveError=1e-16))
                    rows.append(row)
            cls.external=dict(schemaVersion=1,status='qualified',cases=180,frames=4113,
                documentedReferenceDisagreements=6,rows=rows)
            cls.causal=[]
            for name in audit.load_json(CAUSAL/'manifest.json')['catalog']:
                reference=audit.load_json(CAUSAL/(name+'.json'))
                cls.causal.append(dict(name=name,inputSHA256=reference['input']['encodedSHA256'],
                    profileIdentity=audit.identity(reference['profile']),configuration=reference['profile'],
                    **{k:reference['grid'][k] for k in ('completeFrameCount','tailStartSample','tailSampleCount')},
                    chunkResultsExactlyEqual=True,maximumBudgetFractions={k:0. for k in ('center','normalizationMean',
                        'normalizationPeak','localMean','localPeak','relativeIntensity','periodicity','decibels')}))

        def test_complete_qualified_and_causal_reports(self):
            result=audit.validate_external(self.external,EXTERNAL)
            self.assertEqual((result['agreements'],len(result['documentedReferenceDisagreements'])),(4107,6))
            self.assertEqual(audit.validate_causal(self.causal,CAUSAL)['completeFrames'],312)

        def test_external_coverage_states_and_values_cannot_be_hidden(self):
            finite=next(i for i,r in enumerate(self.external['rows']) if r['actualStatus']=='finite')
            changes=[lambda r:r['rows'].pop(),lambda r:r['rows'].append(r['rows'][0]),
                lambda r:r.__setitem__('status','passed'),
                lambda r:r['rows'][finite].__setitem__('actualDB',r['rows'][finite]['actualDB']+1),
                lambda r:r['rows'][finite].__setitem__('budgetFraction',float('nan')),
                lambda r:r['rows'][finite].__setitem__('actualStatus','unavailable'),
                lambda r:r['rows'][0].__setitem__('inputSHA256','0'*64),
                lambda r:r['rows'][0].__setitem__('actualCenterSeconds',0),
                lambda r:r['rows'][0]['configuration'].__setitem__('silenceThreshold',.2)]
            for change in changes:
                bad=copy.deepcopy(self.external);change(bad)
                with self.assertRaises(ValueError):audit.validate_external(bad,EXTERNAL)

        def test_disagreement_requires_numeric_proof_not_case_name(self):
            index=next(i for i,r in enumerate(self.external['rows']) if r.get('proof'))
            changes=[lambda r:r['proof'].__setitem__('maximumCurveError',1e-10),
                lambda r:r['proof'].__setitem__('impulseIndex',0),
                lambda r:r['proof'].__setitem__('windowSamples',960),
                lambda r:r['proof'].__setitem__('expectedCorrelation',0),
                lambda r:r.__setitem__('actualDB',0),lambda r:r.pop('proof')]
            for change in changes:
                bad=copy.deepcopy(self.external);change(bad['rows'][index])
                with self.assertRaises(ValueError):audit.validate_external(bad,EXTERNAL)

        def test_causal_receipts_require_every_case_tail_and_stage(self):
            changes=[lambda r:r.pop(),lambda r:r.append(r[0]),
                lambda r:r[0].__setitem__('chunkResultsExactlyEqual',False),
                lambda r:r[0].__setitem__('tailSampleCount',0),
                lambda r:r[0].__setitem__('inputSHA256','0'*64),
                lambda r:r[0]['maximumBudgetFractions'].pop('periodicity'),
                lambda r:r[0]['maximumBudgetFractions'].__setitem__('localMean',1.01),
                lambda r:r[0]['maximumBudgetFractions'].__setitem__('decibels',float('nan'))]
            for change in changes:
                bad=copy.deepcopy(self.causal);change(bad)
                with self.assertRaises(ValueError):audit.validate_causal(bad,CAUSAL)
    unittest.main()
else:

    class HNRNativeAuditTests(unittest.TestCase):
        # HNR's reference programs deliberately use sibling module names such as
        # catalog/contract. Run them in subprocesses so full-suite discovery cannot
        # replace another reference family's already imported modules.
        def isolated(self, name):
            result=subprocess.run([sys.executable,__file__,f'HNRNativeAuditTests.{name}'],
                cwd=ROOT,capture_output=True,text=True,timeout=120)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

        def test_complete_qualified_and_causal_reports(self):
            self.isolated('test_complete_qualified_and_causal_reports')

        def test_external_coverage_states_and_values_cannot_be_hidden(self):
            self.isolated('test_external_coverage_states_and_values_cannot_be_hidden')

        def test_disagreement_requires_numeric_proof_not_case_name(self):
            self.isolated('test_disagreement_requires_numeric_proof_not_case_name')

        def test_causal_receipts_require_every_case_tail_and_stage(self):
            self.isolated('test_causal_receipts_require_every_case_tail_and_stage')
