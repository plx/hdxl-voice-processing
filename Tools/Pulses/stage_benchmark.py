#!/usr/bin/env python3
"""Measure every accepted/rejected pulse attempt with paired diagnostic kernel replay."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys
import uuid

SPEC = importlib.util.spec_from_file_location('pulse_benchmark', Path(__file__).with_name('benchmark.py'))
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)
ROOT, ci = benchmark.ROOT, benchmark.ci
SHARDS = benchmark.SHARDS[:-1]


def summarize(values):
    if not values: return dict(sampleCount=0, minimum=None, median=None, p95=None, p99=None, maximum=None)
    values = sorted(values)
    return dict(sampleCount=len(values), minimum=values[0], median=statistics.median(values),
                p95=values[math.ceil(.95*len(values))-1], p99=values[math.ceil(.99*len(values))-1], maximum=values[-1])


def validate(report, matrix):
    if type(report['schemaVersion']) is not int or report['schemaVersion'] != 1 or report['definition'] != 'pulse-actual-attempt-kernel-replay-v1':
        raise ValueError('Unknown pulse stage recipe')
    if not isinstance(report['limitations'], str) or any(word not in report['limitations'] for word in ('overhead','production sampling','not full analyzer throughput')):
        raise ValueError('Missing stage scope/overhead limitations')
    expected = {r['workload']['fixture'] + '-' + r['workload']['precision']: r for r in matrix
                if r['workload']['support'] == 'completeInterval'}
    seen = set(); summaries = {}
    for case in report['cases']:
        name = case['name']
        if name not in expected or name in seen: raise ValueError('Unexpected/duplicate pulse stage case')
        seen.add(name); receipt = expected[name]
        for key in ('configuration','profileIdentity','f0ContourIdentity','inputSampleCount','encodedInputSHA256','fixtureJSONSHA256'):
            if benchmark.canonical_module.canonical(case[key]) != benchmark.canonical_module.canonical(receipt[key]):
                raise ValueError('Pulse stage input/recipe identity changed: ' + key)
        attempts = case['attempts']; counts = receipt['counts']
        if not isinstance(attempts,list) or len(attempts) != counts['attempts']: raise ValueError('Incomplete pulse stage attempts')
        for index, attempt in enumerate(attempts):
            if (type(attempt['index']) is not int or attempt['index'] != index
                    or any(type(attempt[k]) is not bool for k in ('acceptedByReferenceGates','eligible','interpolationExpected'))
                    or type(attempt['rejectionBits']) is not int or not 0 <= attempt['rejectionBits'] < 1 << 18
                    or attempt['eligible'] != (attempt['rejectionBits'] == 0)
                    or attempt['eligible'] and not attempt['acceptedByReferenceGates']
                    or attempt['direction'] not in ('backward','forward')):
                raise ValueError('Invalid pulse attempt classification')
            for key in ('fromSeconds','frequencyHz'):
                if type(attempt[key]) not in (int,float) or not math.isfinite(attempt[key]): raise ValueError('Invalid stage coordinate')
            c = case['configuration']
            if not (0 <= attempt['fromSeconds'] <= receipt['inputDurationSeconds']
                    and c['pitchFloorHz'] <= attempt['frequencyHz'] < c['pitchCeilingHz']):
                raise ValueError('Stage attempt outside input/profile')
        if (sum(a['acceptedByReferenceGates'] for a in attempts) != counts['acceptedAttempts']
                or sum(not a['acceptedByReferenceGates'] for a in attempts) != counts['rejectedAttempts']
                or sum(a['eligible'] for a in attempts) != counts['eligibleAttempts']):
            raise ValueError('Stage acceptance denominators changed')
        trials = set(); checksums = set()
        grouped = {f'{status}.{stage}': [] for status in ('accepted','rejected','eligible','ineligible')
                   for stage in ('matching','interpolation')}
        totals = {'disabled': [], 'detailed': []}
        for trial in case['trials']:
            index, mode = trial['index'], trial['mode']
            if type(index) is not int or index not in range(5) or mode not in totals or (index,mode) in trials:
                raise ValueError('Unexpected/duplicate pulse stage trial')
            trials.add((index,mode))
            elapsed, checksum = trial['replayNanoseconds'], trial['checksum']
            if type(elapsed) is not int or elapsed <= 0 or type(checksum) not in (int,float) or not math.isfinite(checksum) or checksum <= 0:
                raise ValueError('Invalid pulse stage clock/checksum')
            checksums.add(checksum); totals[mode].append(elapsed)
            matching, interpolation = trial['matchingNanoseconds'], trial['interpolationNanoseconds']
            for stage, values in (('matching',matching),('interpolation',interpolation)):
                if not isinstance(values,list) or len(values) != len(attempts): raise ValueError('Missing per-attempt stage coverage')
                for attempt, value in zip(attempts, values):
                    measured = mode == 'detailed' and (stage == 'matching' or attempt['interpolationExpected'])
                    invalid = (type(value) is not int or value < 0) if measured else value is not None
                    if invalid: raise ValueError('Incorrect pulse stage sample coverage')
                    if measured:
                        for category in ('accepted' if attempt['acceptedByReferenceGates'] else 'rejected',
                                         'eligible' if attempt['eligible'] else 'ineligible'):
                            grouped[f'{category}.{stage}'].append(value)
            if sum(x for x in matching if x is not None) + sum(x for x in interpolation if x is not None) > elapsed: raise ValueError('Inconsistent stage timing accounting')
        if len(trials) != 10 or len(checksums) != 1: raise ValueError('Missing paired trials or instrumentation changed results')
        summaries[name] = dict(attempts=counts['attempts'], acceptedAttempts=counts['acceptedAttempts'],
            rejectedAttempts=counts['rejectedAttempts'], eligibleAttempts=counts['eligibleAttempts'],
            interpolationSkipped=sum(not a['interpolationExpected'] for a in attempts),
            stages={key:summarize(values) for key,values in grouped.items()},
            replay={key:summarize(values) for key,values in totals.items()})
    if seen != set(expected): raise ValueError('Missing pulse stage cases')
    return summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shard', choices=SHARDS, required=True)
    args = parser.parse_args()
    output = ROOT / '.build/artifacts' / f'pulse-stages-{args.shard}-{uuid.uuid4().hex[:8]}'
    output.mkdir(parents=True); print(output, flush=True)
    result = dict(status='failed', commands=[])
    lock = ROOT / 'Benchmarks/Package.resolved'; before = lock.read_bytes()
    try:
        environment = ci.environment('release')
        ci.validate_environment(environment, json.loads((ROOT / 'Configuration/build.json').read_text()))
        environment.update(hardwareModel=ci.capture('sysctl','-n','hw.model'),
            recipe='Tools/PulseStageProbe/PulseStageProbe.swift',
            sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted([*ROOT.glob('Sources/HDXLVoiceProcessing/**/*.swift'),
                    ROOT/'Tools/PulseStageProbe/PulseStageProbe.swift', ROOT/'Benchmarks/Sources/PulseWorkload/PulseWorkload.swift',
                    Path(__file__), ROOT/'Tools/Pulses/benchmark.py'])},
            evidence='Every actual attempted match is replayed, preserving native gate/eligibility classification. Five paired disabled/detailed trials; inclusive stage samples contain clock/lock overhead. Per-attempt frames prevent prefix sampling. Separate public-worker benchmark supplies full analyzer and allocation evidence.',
            sampling='Five repeated measurements per fixed attempted step; tails characterize this bounded fixture replay, not a general workload population.')
        (output/'environment.json').write_text(ci.redact(json.dumps(environment,indent=2))+'\n')
        common = benchmark.smoke.swift_arguments('timing')
        common[common.index('--scratch-path')+1] = str(ROOT/'.build/pulse-timing')
        with (output/'commands.log').open('w') as log:
            ci.run_command([sys.executable,'Tools/verify-provenance.py'],log,result['commands'])
            ci.run_command(['swift','build',*common,'--product','PulseWorkloadCheck'],log,result['commands'])
            ci.run_command(['swift','build','--scratch-path','.build/ci-release','-c','release','--product','PulseStageProbe'],log,result['commands'])
        directory = Path(benchmark.capture_stdout('swift','build',*common,'--show-bin-path'))
        matrix = json.loads(benchmark.capture_stdout(str(directory/'PulseWorkloadCheck'),'--shard',args.shard))
        benchmark.validate_matrix(matrix,args.shard)
        (output/'workloads.json').write_text(json.dumps(matrix,indent=2)+'\n')
        probe = Path(benchmark.capture_stdout('swift','build','--scratch-path','.build/ci-release','-c','release','--show-bin-path'))/'PulseStageProbe'
        raw = benchmark.capture_stdout(str(probe),'--shard',args.shard)
        (output/'trials.json').write_text(raw+'\n')
        summaries = validate(json.loads(raw), matrix)
        (output/'distributions.json').write_text(json.dumps(summaries,indent=2)+'\n')
        result.update(status='passed',cases=len(summaries),pairedTrials=5*len(summaries),
                      attempts=sum(r['attempts'] for r in summaries.values()))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        result['error'] = ci.redact(str(error)); print(result['error'],file=sys.stderr)
    if lock.read_bytes() != before: result.update(status='failed',error='Benchmark dependency lock changed')
    (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return 0 if result['status']=='passed' else 1


if __name__ == '__main__': sys.exit(main())
