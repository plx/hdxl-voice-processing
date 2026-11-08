#!/usr/bin/env python3
"""Compare independent direct-sum equations against retained external HNR frames."""
import argparse
import json
from pathlib import Path
import time

from catalog import ROOT, cases, source_samples
from common import canonical, load_json
from contract import COMPARISON, comparison_fraction, reference_state
from degeneracy import impulse_plateau
import oracle
from reference import sha
from verify import verify


def check_equations(directory,output):
    directory=Path(directory).resolve();output=Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT/'.build').resolve()):
        raise ValueError('Use an absent equation-evidence directory under .build')
    verification=verify(directory)
    output.mkdir(parents=True)
    rows=[];failures=[];disagreements=[]
    for case in cases():
        samples=source_samples(case)
        expected=load_json(directory/(case['name']+'.json'))['data']['frames']
        for index in sorted({0,len(expected)//2,len(expected)-1}):
            started=time.perf_counter();actual=oracle.frame(samples,case['profile'],index)
            state=reference_state(actual['rawReferenceDB']);ref=expected[index]
            fraction=None
            if state['status']==ref['status']:
                fraction=0. if state['status']!='finite' else comparison_fraction(
                    state['valueDB'],ref['valueDB'])
            row={'name':case['name'],'frameIndex':index,'expectedStatus':ref['status'],
                 'actualStatus':state['status'],'expectedDB':ref['valueDB'],
                 'actualDB':state['valueDB'],'budgetFraction':fraction,
                 'candidateCount':len(actual['candidates']),'seconds':time.perf_counter()-started}
            if fraction is None or fraction>1:
                proof=impulse_plateau(samples,case['profile'],actual)
                if proof and state['status']=='unavailable' and ref['status']=='finite':
                    row.update(disposition='documentedReferenceDisagreement',proof=proof)
                    disagreements.append(row)
                else:
                    row['disposition']='unexplainedFailure';failures.append(row)
            else:row['disposition']='agreement'
            rows.append(row)
        print(case['name'],len(rows),'equation comparisons;',len(failures),'outside policy',flush=True)
    sources=['Tools/HNR/oracle.py','Tools/HNR/degeneracy.py','Tools/HNR/check_equations.py','Tools/HNR/catalog.py','Tools/HNR/contract.py']
    report={'schemaVersion':1,'status':'failed' if failures else ('qualified' if disagreements else 'passed'),
            'referenceManifestSHA256':sha((directory/'manifest.json').read_bytes()),
            'sourceSHA256':{p:sha((ROOT/p).read_bytes()) for p in sources},
            'comparisonPolicy':COMPARISON,'referenceVerification':verification,
            'coverage':'first/middle/last distinct complete frame of every catalog case; all differences retained',
            'comparisons':len(rows),'maximumBudgetFraction':max((r['budgetFraction'] for r in rows if r['budgetFraction'] is not None),default=0),
            'agreements':len(rows)-len(failures)-len(disagreements),
            'documentedReferenceDisagreements':disagreements,'failures':failures,'rows':rows}
    (output/'equations.json').write_bytes(canonical(report))
    print(json.dumps({k:report[k] for k in ('status','comparisons','agreements','maximumBudgetFraction','failures')}),flush=True)
    if failures:raise ValueError('Independent equations disagree with the reference; inspect retained failures')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();check_equations(args.directory,args.output)
