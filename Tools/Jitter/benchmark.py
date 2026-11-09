#!/usr/bin/env python3
"""Measure independently checked jitter preparation, statistics and PCM costs."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

from performance_receipts import (ROOT, SHARDS, benchmark_names, operation_costs,
    validate_export, validate_matrix, validate_raw)

sys.path.insert(0,str(ROOT/'Tools'))
import ci
SPEC=importlib.util.spec_from_file_location('jitter_smoke_benchmark',ROOT/'Tools/benchmark.py')
smoke=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)
PACKAGE=ROOT/'Benchmarks'


def capture_stdout(*command):
    return subprocess.run(command,cwd=ROOT,text=True,capture_output=True,check=True).stdout.strip()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=('timing','allocation'))
    parser.add_argument('--shard',choices=SHARDS,required=True)
    args=parser.parse_args()
    output=PACKAGE/'.build/artifacts'/f'jitter-{args.mode}-{args.shard}-{uuid.uuid4().hex[:8]}'
    output.mkdir(parents=True)
    print(str(output),flush=True)
    result=dict(schemaVersion=1,mode=args.mode,shard=args.shard,status='failed',commands=[])
    lock=PACKAGE/'Package.resolved'; before=lock.read_bytes()
    name=f'jitter-{args.mode}-{args.shard}-{uuid.uuid4().hex}'
    baseline=PACKAGE/'.benchmarkBaselines/JitterBenchmarks'/name
    try:
        overrides=('MALLOC_INTERPOSER_LOCAL_PATH','RUNTIME_INTERPOSER_LOCAL_PATH',
            'BENCHMARK_DISABLE_MALLOC_INTERPOSER','BENCHMARK_DISABLE_JEMALLOC','DYLD_INSERT_LIBRARIES','LD_PRELOAD')
        if any(k in os.environ for k in overrides): raise ValueError('Remove allocator/backend environment overrides')
        environment=ci.environment('release')
        ci.validate_environment(environment,json.loads((ROOT/'Configuration/build.json').read_text()))
        environment.update(hardwareModel=ci.capture('sysctl','-n','hw.model'),mode=args.mode,shard=args.shard,
            purpose='A13 period-statistics and incremental rolling costs, with separate pinned PCM comparison; physical evidence deferred74/102',
            packageResolvedSHA256=hashlib.sha256(before).hexdigest(),frameworkScalingFactor=1,
            exportStatistic='p99 per declared operation; distributions retained',
            sampling='Three warmups, thirty measured operations, 600s cap; thirty required. p99 of thirty is near the maximum, not a stable population tail estimate.',
            operations={
                'Prepare':'Construct/destroy one combined prepared worker and bounded buffers; input/contour creation excluded. Five separate workers are prepared before measuring Separate.',
                'Combined':'Batch: one all-variant query. Rolling: append one additional window of observations, query after each, consume every result. One prior window is seeded outside the measurement.',
                'Separate':'Same input and consumption, using five genuine single-variant workers; includes their separate coverage calculations and rolling state maintenance.',
                'QueryOnly':'One rolling result from already populated state; reset and all appends excluded. No expirations are due at this clock.',
                'PulseOnly':'Complete borrowed pulse analysis and bounded pulse/period consumption; reset excluded.',
                'PCMCombined':'Same pulse analysis plus mapping, combined jitter, and result consumption; reset excluded.',
                'StatisticsOnly':'Prepared jitter on the exact same qualified periods captured during untimed PCM setup; no pulse tracking, copying or export inside measurement.'},
            inputs='Original alternating +/-1% period recipe at80/600Hz; .25/1/3/10s, accepted and5of11source-rejected periods. Rolling input has two windows and measures the second. Double period arithmetic for both declared upstream PCM precisions. PCM comparison uses existing pinned .5s Gaussian80/600Hz fixtures, both precisions.',
            timing='Direct supplied-period dependencies pad fractional endpoints by one sample; rolling source clock/window are integer-valued. PCM retains full-block dependency and supplied F0 grid. Hop definitions and frame/window/input counts are in workloads.json.',
            correctness='Original100-digit Decimal formulas check declared supplied periods/flags and exact membership/counts. PCM inputs/F0/profiles and raw pulse positions checked against frozen references; this benchmark does not independently relabel tracker reliability.',
            workingMemory='Pinned arm64 Swift6.4 buffer layouts; all owned input/contour/period/support arrays reported separately from prepared buffers. Object bookkeeping and allocator resident-memory/leak metrics are not claimed.',
            allocationClaim='Every non-Prepare operation must have zero malloc/object/byte maxima with a positive allocation/free/ARC control. Timing and allocation modes use separate binaries; instrumentation disabled in workers.',
            distributions='raw-baseline.json.gz, distributions.json, p99.json; costs.json contains throughput and explicit amortized update cost, never subtraction-derived pulse/statistics stage timing.')
        paths=[*ROOT.glob('Sources/HDXLVoiceProcessing/**/*.swift'),
            *ROOT.glob('Benchmarks/Sources/JitterWorkload/**/*.swift'),
            ROOT/'Benchmarks/Sources/JitterWorkloadCheck/main.swift',
            ROOT/'Benchmarks/Benchmarks/JitterBenchmarks/JitterBenchmarks.swift',
            ROOT/'Package.swift',ROOT/'Benchmarks/Package.swift',
            *ROOT.glob('Tools/Jitter/*.py'),ROOT/'Tools/benchmark.py',ROOT/'Tools/ci.py']
        environment['sourceSHA256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
        (output/'environment.json').write_text(ci.redact(json.dumps(environment,indent=2))+'\n')
        (output/'resolution.json').write_bytes(before)
        common=smoke.swift_arguments(args.mode)
        common[common.index('--scratch-path')+1]=str(ROOT/'.build'/('jitter-'+args.mode))
        plugin=['swift','package',*common,'--allow-writing-to-package-directory','benchmark',
            '--target','JitterBenchmarks','--time-units','nanoseconds','--no-progress']
        with (output/'commands.log').open('w') as log:
            def run(command): ci.run_command(command,log,result['commands'])
            run([sys.executable,'Tools/verify-provenance.py'])
            run(['swift','build',*common,'--product','JitterWorkloadCheck'])
            binary_dir=Path(capture_stdout('swift','build',*common,'--show-bin-path'))
            matrix=json.loads(capture_stdout(str(binary_dir/'JitterWorkloadCheck'),'--shard',args.shard))
            validate_matrix(matrix,args.shard)
            (output/'workloads.json').write_text(json.dumps(matrix,indent=2)+'\n')
            names=benchmark_names(matrix,args.mode)
            plugin+=['--filter','^('+'|'.join(re.escape(n) for n in sorted(names))+')$']
            if baseline.exists(): raise ValueError('Fresh jitter baseline already exists')
            run([*plugin,'baseline','update',name])
            raw=json.loads((baseline/'results.json').read_text())
            if raw.get('baselineName')!=name: raise ValueError('Raw capture identity differs from this run')
            raw['machine']['hostname']='<host>'
            with gzip.open(output/'raw-baseline.json.gz','wt') as stream:
                json.dump(raw,stream,separators=(',',':'),allow_nan=False)
            distributions=validate_raw(raw,matrix,args.mode)
            (output/'distributions.json').write_text(json.dumps(distributions,indent=2)+'\n')
            result['binary']=smoke.inspect_binary(binary_dir/'JitterBenchmarks',args.mode)
            run([*plugin,'baseline','read',name,'--format','jsonSmallerIsBetter','--path',str(output)])
            values=validate_export(json.loads((output/(name+'.json')).read_text()),names,args.mode)
            (output/'p99.json').write_text(json.dumps(values,indent=2)+'\n')
            if args.mode=='timing': (output/'costs.json').write_text(json.dumps(operation_costs(matrix,values),indent=2)+'\n')
            (output/(name+'.json')).unlink()
            result.update(status='passed',workloadCount=len(matrix),benchmarkCount=len(distributions),metricCount=len(values),
                preparedRunAllocationMaximum=0 if args.mode=='allocation' else None,
                allocationEvidence='positive control plus zero-heap prepared operations' if args.mode=='allocation' else 'instrumentation disabled')
    except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError) as error:
        result['error']=ci.redact(str(error)); print(result['error'],file=sys.stderr)
    finally:
        if baseline.exists(): shutil.rmtree(baseline)
        if lock.read_bytes()!=before: result.update(status='failed',error='Package.resolved changed during locked measurement')
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return 0 if result['status']=='passed' else 1


if __name__=='__main__':
    sys.exit(main())
