#!/usr/bin/env python3
"""Measure actual HNR worker scopes, retaining inclusive instrumented distributions."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys

SPEC = importlib.util.spec_from_file_location('hnr_benchmark', Path(__file__).with_name('benchmark.py'))
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)

ROOT = benchmark.ROOT
ci = benchmark.ci
STAGES = ('hnrNormalization','analysisFrame','hnr','hnrWindow','hnrCorrelation','hnrPeriodSearch','fft')


def validate(report, rate=None):
    if report['schemaVersion'] != 1 or report['definition'] != 'hnr-worker-stage-clock-probe-v1':
        raise ValueError('Unexpected HNR stage probe recipe')
    if not isinstance(report['limitations'],str) or 'overhead' not in report['limitations']:
        raise ValueError('Stage instrumentation overhead must be explicit')
    expected={}
    for name,row in benchmark.expected_cases().items():
        if row['kind']!='Harmonic' or rate is not None and row['rate']!=rate: continue
        profile=benchmark.expected_profile(row)
        digest=hashlib.sha256(benchmark.canonical_module.canonical(profile)).hexdigest()
        expected[digest]=(row,profile)
    seen=set(); checksums={}; grouped={}
    for trial in report['trials']:
        identity=trial['profileIdentity']; digest=identity['sha256']
        if digest not in expected: raise ValueError('Unexpected stage profile')
        row,profile=expected[digest]
        if benchmark.canonical_module.canonical(trial['configuration'])!=benchmark.canonical_module.canonical(profile) or identity['identifier']!={'name':f"hdxl-hnr-{row['method']}-{profile['normalization']}",'version':1}:
            raise ValueError('Stage recipe identity mismatch')
        index,mode=trial['trial'],trial['mode']
        if type(index) is not int or index not in range(5) or mode not in ('disabled','detailed'):
            raise ValueError('Unexpected stage trial')
        key=(digest,index,mode)
        if key in seen: raise ValueError('Duplicate stage trial')
        seen.add(key)
        n=row['count']; sample_rate=row['rate']; whole=row['normalization']=='whole'
        if whole:
            full=math.floor(((1/sample_rate)*n-row['support'])/profile['hopSeconds'])+1
        else:
            from fractions import Fraction
            step=Fraction.from_float(profile['hopSeconds']*sample_rate)
            full=0
            while (full*step).__floor__()+row['causal']<=n: full+=1
        if trial['inputSampleCount']!=n or trial['completeFrames']!=full:
            raise ValueError('Stage input or frame coverage mismatch')
        elapsed=trial['nanoseconds']; checksum=trial['checksum']
        if type(elapsed) is not int or elapsed<=0 or type(checksum) not in (float,int) or not math.isfinite(checksum) or checksum<=0:
            raise ValueError('Invalid stage timing/checksum')
        if digest in checksums and checksums[digest]!=checksum: raise ValueError('Instrumentation changed results')
        checksums[digest]=checksum
        stages=trial['stageNanoseconds']
        if set(stages)!=set(STAGES): raise ValueError('Missing or extra stage')
        for stage,values in stages.items():
            count=0 if mode=='disabled' else (1 if whole else full) if stage=='hnrNormalization' else full*(2 if row['method']=='ac' else 3) if stage=='fft' else full
            if not isinstance(values,list) or len(values)!=count or any(type(x) is not int or x<=0 for x in values):
                raise ValueError(f'Incorrect stage sample coverage: {stage}')
            grouped.setdefault(digest,{}).setdefault(stage,[]).extend(values)
        totals={stage:sum(values) for stage,values in stages.items()}
        if not (totals['fft']<=totals['hnrCorrelation'] and
                totals['hnrWindow']+totals['hnrCorrelation']+totals['hnrPeriodSearch']<=totals['hnr']<=totals['analysisFrame'] and
                totals['hnrNormalization']+totals['analysisFrame']<=elapsed):
            raise ValueError('Inclusive stage accounting is inconsistent')
    if len(seen)!=len(expected)*10: raise ValueError('Missing stage trials or profiles')
    summaries={}
    for digest,stages in grouped.items():
        summary={}
        for stage,values in stages.items():
            values.sort()
            def percentile(p): return values[max(0,math.ceil(p*len(values))-1)]
            summary[stage]=dict(sampleCount=len(values),minimum=values[0],median=statistics.median(values),
                p95=percentile(.95),p99=percentile(.99),maximum=values[-1])
        summaries[digest]=summary
    return summaries


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rate',type=int,choices=(16000,44100,48000),required=True)
    args=parser.parse_args()
    output=ROOT/'.build/artifacts'/f'hnr-stages-{args.rate}'
    output.mkdir(parents=True,exist_ok=True)
    result=dict(status='failed',commands=[])
    try:
        environment=ci.environment('release')
        ci.validate_environment(environment,json.loads((ROOT/'Configuration/build.json').read_text()))
        environment.update(hardwareModel=ci.capture('sysctl','-n','hw.model'),
            recipe='Tools/HNRStageProbe/HNRStageProbe.swift',
            sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted([*ROOT.glob('Sources/HDXLVoiceProcessing/**/*.swift'), ROOT/'Tools/HNRStageProbe/HNRStageProbe.swift',Path(__file__)])},
            evidence='Actual internal HNR spans, five paired disabled/detailed trials per profile, warmed before measurement. Inclusive stage cost includes bounded sink clock/lock overhead. Separate benchmark suite supplies uninstrumented latency and allocation evidence.')
        (output/'environment.json').write_text(ci.redact(json.dumps(environment,indent=2))+'\n')
        with (output/'commands.log').open('w') as log:
            ci.run_command(['swift','build','-c','release','--product','HNRStageProbe'],log,result['commands'])
        directory=ci.capture('swift','build','-c','release','--show-bin-path')
        command=[str(Path(directory)/'HNRStageProbe'),'--rate',str(args.rate)]
        result['probeCommand']=command
        raw=ci.capture(*command)
        (output/'trials.json').write_text(raw+'\n')
        summaries=validate(json.loads(raw),args.rate)
        (output/'distributions.json').write_text(json.dumps(summaries,indent=2)+'\n')
        result.update(status='passed',profileCount=len(summaries),pairedTrialCount=5*len(summaries))
    except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError) as error:
        result['error']=ci.redact(str(error));print(result['error'],file=sys.stderr)
    (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return 0 if result['status']=='passed' else 1


if __name__=='__main__': sys.exit(main())
