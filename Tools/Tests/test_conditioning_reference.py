"""Offline integrity/analytic checks; external Praat regeneration has its own lane."""
import copy
import importlib.util
import json
import math
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('conditioning_reference',ROOT/'Tools/Conditioning/reference.py')
reference=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(reference)


class ConditioningReferenceTests(unittest.TestCase):
    def test_published_raw_filter_has_explicit_initial_state_and_no_gain_normalization(self):
        source=[0.25,0.5,-0.125,0.75,0.1,-0.3,0.2]
        a=math.exp(-math.tau*50/16000)
        actual=[reference.raw_pre_emphasis(x,source[i-1] if i else 0,50,16000,i) for i,x in enumerate(source)]
        self.assertEqual(actual[0],source[0])
        self.assertEqual(actual[1],0.5-a*0.25)
        self.assertEqual(reference.raw_pre_emphasis(0.5,0.25,None,16000,1),0.5)
        self.assertEqual(reference.raw_pre_emphasis(0.5,0.25,0,16000,1),0.25)
        self.assertNotEqual(max(map(abs,actual)),0.99)

    def test_parser_rejects_missing_duplicate_nonfinite_and_malformed_exports(self):
        valid='axis\t2\t10000\t0\t0.0002\t0.00005\nsample\t0\t0.25\t0\nsample\t1\t0.5\t0.25\n'
        self.assertEqual(reference.parse(valid)['resampled'],[0.25,0.5])
        for bad in (valid.replace('sample\t1','sample\t0'),valid.replace('0.5\t0.25','nan\t0.25'),
                    valid.replace('sample\t0\t0.25\t0','sample\t0\t0.25\t1'),
                    '\n'.join(valid.splitlines()[:-1]),valid.replace('axis\t2','axis\t2.5'),valid+'extra\n'):
            with self.assertRaises((ValueError,IndexError)): reference.parse(bad)

    def test_committed_input_identity_and_raw_filter_expectations_are_independent(self):
        fixture=json.loads(reference.OUTPUT.read_text())
        self.assertEqual(fixture['generatorSHA256'],reference.implementation_hash())
        self.assertEqual(len(fixture['cases']),184)
        self.assertEqual(len({(c['name'],c['precision']) for c in fixture['cases']}),184)
        for case in fixture['cases']:
            # Long source regeneration/hash checking also occurs in native and external lanes.
            # This offline suite bounds routine Python work at moderate reference inputs.
            if case['inputRecipe']['count']<=48000:
                source=reference.samples(case['inputRecipe'],case['precision'])
                self.assertEqual(case['inputSHA256'],reference.input_hash(source,case['precision']))
                if case['input'] is not None: self.assertEqual(case['input'],source)
            expected=case['expected']
            conditioned=[reference.raw_pre_emphasis(x,p,case['preEmphasisFromHz'],case['targetRate'],i)
                         for i,x,p in zip(expected['indices'],expected['resampled'],expected['previousResampled'])]
            self.assertEqual(conditioned,expected['conditioned'])
        menu=fixture['menuCalibration']
        self.assertEqual(max(map(abs,menu['menu'])),0.99)
        self.assertEqual(menu['raw'][0],menu['input'][0])
        self.assertNotEqual(menu['menu'][0],menu['input'][0])
        for x,y in zip(menu['raw'],menu['menu']): self.assertEqual(x*menu['scaleToPeak099'],y)

    def test_regeneration_verifier_detects_definition_and_numeric_changes(self):
        original=json.loads(reference.OUTPUT.read_text())
        reference.verify(original,copy.deepcopy(original))
        for key in ('targetRate','maximumAbsoluteError'):
            bad=copy.deepcopy(original); bad['cases'][0][key]*=2
            with self.assertRaises(ValueError): reference.verify(bad,original)
        bad=copy.deepcopy(original); bad['cases'][0]['expected']['resampled'][0]+=1e-7
        with self.assertRaises(ValueError): reference.verify(bad,original)
        bad=copy.deepcopy(original); bad['cases'].pop()
        with self.assertRaises(ValueError): reference.verify(bad,original)
