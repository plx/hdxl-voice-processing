#!/usr/bin/env python3
"""Strictly audit native HNR reports against the frozen or regenerated references."""
import argparse
import hashlib
import json
import math
from pathlib import Path

from catalog import cases, source_samples
from common import canonical, load_json
from contract import comparison_fraction, finite
from streaming import native_profile


def require(value,message):
    if not value: raise ValueError(message)


def profile(reference):
    p=native_profile(reference['method'],reference['sampleRate'],reference['inputPrecision'])
    for key in ('pitchFloorHz','periodsPerWindow','hopSeconds','silenceThreshold'): p[key]=reference[key]
    p.update(normalization='wholeIntervalMeanRemovedPeak',frameGrid='centeredWholeIntervalBinary64FusedStep')
    return p


def identity(p):
    return dict(identifier=dict(name=f"hdxl-hnr-{p['method']}-{p['normalization']}",version=1),
        sha256=hashlib.sha256(canonical(p)).hexdigest())


def validate_external(report,directory):
    directory=Path(directory)
    expected={c['name']:c for c in cases()}
    references={name:load_json(directory/(name+'.json')) for name in expected}
    require(report['schemaVersion']==1 and report['status']=='qualified','Missing qualified native audit identity')
    require(report['cases']==180 and report['frames']==4113 and report['documentedReferenceDisagreements']==6,'Incorrect native audit totals')
    seen=set(); proofs=[]; maximum=0.
    for row in report['rows']:
        name=row['name']; index=row['frameIndex']
        require(name in expected and type(index) is int,'Unexpected native case/frame')
        reference=references[name]; frames=reference['data']['frames']
        require(0<=index<len(frames) and (name,index) not in seen,'Missing, duplicate or extra native frame')
        seen.add((name,index)); wanted=frames[index]; p=profile(expected[name]['profile'])
        require(canonical(row['configuration'])==canonical(p) and row['profileIdentity']==identity(p),'Incorrect native profile identity')
        require(row['inputSHA256']==reference['input']['encodedSHA256'],'Incorrect native input identity')
        require(row['expectedCenterSeconds']==wanted['centerSeconds']==row['actualCenterSeconds'],'Native frame axis changed')
        require(row['expectedStatus']==wanted['status'] and row.get('expectedDB')==wanted['valueDB'],'Native expected data differs from reference')
        proof=row.get('proof')
        if proof is not None:
            require(p['method']=='cc' and wanted['status']=='finite' and row['actualStatus']=='unavailable'
                and row.get('actualDB') is None and row.get('actualDecibelStatus') is None and row.get('budgetFraction') is None,
                'Invalid reference disagreement disposition')
            samples=source_samples(expected[name]); impulses=[i for i,v in enumerate(samples) if v!=0]
            n=2*(math.floor((p['periodsPerWindow']/p['pitchFloorHz'])/(1/p['sampleRate']))//2-1)
            k=2*math.floor(1/(1/p['sampleRate'])/p['pitchFloorHz'])
            lag=min(math.floor(n/p['periodsPerWindow'])+2,n)
            dx=1/p['sampleRate']; center=wanted['centerSeconds']; split=math.floor(1+(center-.5*dx)/dx)
            mean_start=split-k//2
            first_time=center-.5*(1/p['pitchFloorHz']+p['periodsPerWindow']/p['pitchFloorHz'])
            correlation_start=max(0,math.floor(1+(first_time-.5*dx)/dx)-1)
            require(len(impulses)==1 and proof['impulseIndex']==impulses[0],'Flat-curve proof does not have exactly one impulse')
            i=impulses[0]
            require(mean_start<=i<mean_start+k and correlation_start+lag<=i<correlation_start+n,'Impulse is not in every compared overlap')
            require(proof['definition']=='singleImpulseFlatCCLagCurve' and proof['windowSamples']==n
                and proof['meanSamples']==k and proof['comparedLagCount']==lag,'Incorrect flat-curve proof geometry')
            require(proof['expectedCorrelation']==(n-2*k)/(k*k-2*k+n) and finite(proof['maximumCurveError'])
                and 0<=proof['maximumCurveError']<=2e-14,'Flat-curve evidence exceeds numerical budget')
            proofs.append((name,index)); continue
        require(row['actualStatus']==wanted['status'],'Native availability/limit mismatch')
        status=row['actualStatus']; actual=row.get('actualDB'); typed=row.get('actualDecibelStatus')
        if status=='unavailable': require(actual is None and typed is None,'Unavailable frame has a numeric value')
        elif status=='finite': require(finite(actual) and typed=='finite','Finite frame lost its typed value')
        elif status=='upperReportingLimit': require(actual==150 and typed in ('upperReportingLimit','numericalZeroNoise'),'Upper limit state lost')
        elif status=='lowerReportingLimit': require(actual==-150 and typed=='lowerReportingLimit','Lower limit state lost')
        else: raise ValueError('Unknown HNR state')
        fraction=comparison_fraction(actual,wanted['valueDB']) if status=='finite' else 0.
        reported=row.get('budgetFraction')
        require(finite(reported) and 0<=reported<=1 and fraction<=1 and abs(fraction-reported)<=2e-5,
            'Native numerical comparison exceeded or misstated budget')
        maximum=max(maximum,fraction)
    require(seen=={(n,i) for n,r in references.items() for i in range(len(r['data']['frames']))},'Incomplete native frame coverage')
    require(len(proofs)==6,'Incorrect proven disagreement count')
    return dict(status='qualified',cases=len(expected),frames=len(seen),agreements=len(seen)-len(proofs),
        documentedReferenceDisagreements=[dict(name=n,frameIndex=i) for n,i in proofs],maximumBudgetFraction=maximum)


def validate_causal(rows,directory):
    directory=Path(directory); names=load_json(directory/'manifest.json')['catalog']; seen=set(); frames=0
    budget_keys={'center','normalizationMean','normalizationPeak','localMean','localPeak','relativeIntensity','periodicity','decibels'}
    maximum={k:0. for k in budget_keys}
    for row in rows:
        name=row['name']; require(name in names and name not in seen,'Missing, extra or duplicate causal case');seen.add(name)
        reference=load_json(directory/(name+'.json')); grid=reference['grid']; p=reference['profile']
        require(row['inputSHA256']==reference['input']['encodedSHA256'] and row['profileIdentity']==identity(p)
            and canonical(row['configuration'])==canonical(p),'Incorrect causal input/profile identity')
        require(all(row[k]==grid[k] for k in ('completeFrameCount','tailStartSample','tailSampleCount')),'Incorrect causal full/tail coverage')
        require(row['chunkResultsExactlyEqual'] is True,'Causal chunking changed results')
        budgets=row['maximumBudgetFractions'];require(set(budgets)==budget_keys,'Missing causal numerical stage budget')
        for k,v in budgets.items():
            require(finite(v) and 0<=v<=1,'Causal numerical budget exceeded');maximum[k]=max(maximum[k],v)
        frames+=row['completeFrameCount']
    require(seen==set(names) and len(rows)==12 and frames==312,'Incomplete causal audit')
    return dict(status='passed',cases=len(rows),completeFrames=frames,partialTails=len(rows),maximumBudgetFractions=maximum)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-directory',type=Path,required=True)
    parser.add_argument('--native-report',type=Path,required=True)
    parser.add_argument('--causal-directory',type=Path,required=True)
    parser.add_argument('--causal-report',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    result=dict(external=validate_external(load_json(args.native_report),args.reference_directory),
        causal=validate_causal(load_json(args.causal_report),args.causal_directory))
    args.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))


if __name__=='__main__': main()
