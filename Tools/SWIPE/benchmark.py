#!/usr/bin/env python3
"""Measure paired SWIPE-prime/YIN workloads with independently checked evidence."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools'))
sys.path.insert(0, str(ROOT / 'Tools/SWIPE'))
import ci
from workloads import SHARDS, validate_matrix

_spec = importlib.util.spec_from_file_location('swipe_benchmark_framework', ROOT / 'Tools/benchmark.py')
smoke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(smoke)
PACKAGE = ROOT / 'Benchmarks'
TARGET = 'SWIPEPrimeBenchmarks'
CONTROL = 'Capability.SWIPEPrimeAllocationARC'
OPERATIONS = ('Prepare', 'Run')
ALLOCATIONS = ('mallocCountTotal', 'mallocBytesCount', 'objectAllocCount')
DIAGNOSTICS = (*ALLOCATIONS, 'freeCountTotal', 'retainCount', 'releaseCount')


def benchmark_name(row, operation):
    return f"SWIPEComparison.{row['algorithm']}.{operation}.{row['workload']['name']}"


def validate_raw(raw, matrix, mode):
    if mode not in ('timing', 'allocation'):
        raise ValueError('Unknown measurement mode')
    expected = {benchmark_name(row, operation) for row in matrix for operation in OPERATIONS}
    if mode == 'allocation':
        expected.add(CONTROL)
    rows = raw['results']
    if type(rows) is not list or len(rows) != 2 * len(expected):
        raise ValueError('Missing or extra raw benchmark distributions')
    prepared_runs = {benchmark_name(row, 'Run') for row in matrix
                     if row['workload']['kind'] != 'OwnedDiagnostics'}
    required = {'wallClock', 'cpuTotal'} if mode == 'timing' else {'wallClock', *DIAGNOSTICS}
    result = {}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        if type(identity) is not dict or type(measurements) is not list:
            raise ValueError('Malformed benchmark identity/distribution')
        name = identity.get('name')
        if type(name) is not str or name not in expected or name in result or identity.get('target') != TARGET:
            raise ValueError('Unexpected or duplicate paired benchmark')
        metrics = {}
        for measurement in measurements:
            metric_record = measurement['metric']
            if (type(metric_record) is not dict or len(metric_record) != 1
                    or type(measurement['scalingFactor']) is not int or measurement['scalingFactor'] != 1):
                raise ValueError('Unexpected metric identity or framework scaling')
            metric = next(iter(metric_record))
            histogram = measurement['statistics']['histogram']
            count, maximum = histogram['_totalCount'], histogram['maxValue']
            if metric in metrics or metric not in required or type(count) is not int or count < 10:
                raise ValueError('Missing/duplicate metric or fewer than ten measured samples')
            buckets = histogram['counts']
            if (type(maximum) is not int or maximum < 0 or type(buckets) is not list or not buckets
                    or any(type(v) is not int or v < 0 for v in buckets) or sum(buckets) != count):
                raise ValueError('Malformed histogram evidence')
            if metric == 'wallClock' and maximum <= 0:
                raise ValueError('No positive workload duration')
            if mode == 'allocation':
                if name == CONTROL and metric in DIAGNOSTICS and maximum <= 0:
                    raise ValueError(f'Unavailable allocation/ARC capability: {metric}')
                if name in prepared_runs and metric in ALLOCATIONS and maximum != 0:
                    raise ValueError(f'Prepared allocation observed: {name}, {metric}, maximum={maximum}')
            metrics[metric] = dict(sampleCount=count, maximum=maximum)
        if metrics.keys() != required:
            raise ValueError('Missing metric coverage')
        result[name] = metrics
    if result.keys() != expected:
        raise ValueError('Missing workload coverage')
    return result


def validate_export(rows, names, mode):
    if mode not in ('timing', 'allocation'):
        raise ValueError('Unknown measurement mode')
    metrics = ('Time (wall clock)', 'Time (total CPU)') if mode == 'timing' else (
        'Time (wall clock)', *smoke.DIAGNOSTICS)
    expected = {f'{name} - {metric}' for name in names for metric in metrics}
    result = {}
    if type(rows) is not list:
        raise ValueError('Expected p99 export rows')
    for row in rows:
        name, value = row['name'], row['value']
        if (type(name) is not str or name not in expected or name in result
                or type(value) not in (int, float) or not math.isfinite(value) or value < 0):
            raise ValueError('Invalid p99 benchmark export')
        if row['unit'] != ('ns' if ' - Time (' in name else '#'):
            raise ValueError('Unexpected benchmark unit')
        result[name] = value
    if result.keys() != expected:
        raise ValueError('Missing p99 export metrics')
    return result


def capture_workloads(command, log, records):
    """Keep native progress on stderr separate from its JSON document."""
    started = time.monotonic()
    log.write('+ ' + ci.redact(' '.join(command)) + '\n')
    process = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    log.write(ci.redact(process.stderr))
    log.flush()
    records.append(dict(command=[ci.redact(arg) for arg in command], exitCode=process.returncode,
                        durationSeconds=round(time.monotonic() - started, 3)))
    if process.returncode:
        raise RuntimeError(f'Workload checker exited {process.returncode}')
    return json.loads(process.stdout)


def source_hashes():
    paths = set((ROOT / 'Sources/HDXLVoiceProcessing').rglob('*.swift'))
    paths.update(p for p in (ROOT / 'Benchmarks').rglob('*.swift')
                 if '.build' not in p.relative_to(ROOT / 'Benchmarks').parts)
    paths.update((ROOT / 'Tools/SWIPE').glob('*.py'))
    paths.update(ROOT / name for name in (
        'Package.swift', 'Benchmarks/Package.resolved', 'Configuration/build.json',
        'Tools/ci.py', 'Tools/benchmark.py', 'Tools/Reference/common.py', 'Tools/YIN/oracle.py'))
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('timing', 'allocation'))
    parser.add_argument('--shard', choices=SHARDS, required=True)
    args = parser.parse_args()
    output = PACKAGE / '.build/artifacts' / f'swipe-prime-{args.mode}-{args.shard}'
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = dict(schemaVersion=1, mode=args.mode, shard=args.shard, status='failed', commands=[])
    lock = PACKAGE / 'Package.resolved'
    before = lock.read_bytes()
    name = f'swipe-prime-{args.mode}-{args.shard}-{uuid.uuid4().hex}'
    baseline = PACKAGE / '.benchmarkBaselines' / TARGET / name
    sources = source_hashes()
    raw_preserved = False
    try:
        overrides = ('MALLOC_INTERPOSER_LOCAL_PATH', 'RUNTIME_INTERPOSER_LOCAL_PATH',
                     'BENCHMARK_DISABLE_MALLOC_INTERPOSER', 'BENCHMARK_DISABLE_JEMALLOC',
                     'DYLD_INSERT_LIBRARIES', 'LD_PRELOAD')
        if any(key in os.environ for key in overrides):
            raise ValueError('Remove allocator/backend environment overrides')
        environment = ci.environment('release')
        ci.validate_environment(environment, json.loads((ROOT / 'Configuration/build.json').read_text()))
        environment.update(dict(
            hardwareModel=ci.capture('sysctl', '-n', 'hw.model'), mode=args.mode, shard=args.shard,
            purpose='A10 optional SWIPE-prime and raw YIN FFT on identical inputs; physical evidence deferred #74',
            packageResolvedSHA256=hashlib.sha256(before).hexdigest(), sourceSHA256=sources,
            frameworkScalingFactor=1, exportStatistic='p99 of one declared Prepare or Run operation',
            sampling='Run: one warmup, ten measured operations, 3600s cap. Prepare/control: three warmups, '
                     'thirty measured operations, 60s cap. At least ten samples required. p99 of ten is '
                     'effectively the maximum, not a stable population tail estimate.',
            distributions='raw-baseline.json.gz, distributions.json, p99.json',
            input='125/250/375Hz harmonic PCM (.4/.1/.04 amplitudes, second phase .13), silence, or UInt32 '
                  'LCG seed44 noise. Round once to source precision. Independent recipes reproduce exact PCM hashes.',
            operations=dict(Prepare='Construct estimator, framer, FFT plans and candidate kernels. '
                            'Input generation and destructor are outside the interval.',
                            Run='Reset, process prepared input in256-sample chunks, consume scalar results, '
                            'finalize one partial tail. OwnedDiagnostics additionally copies intermediate '
                            'arrays and encodes JSON, consuming scalar values and encoded byte counts.'),
            workingMemory='Exact owned buffer payloads on64-bit Apple ABI; excludes object bookkeeping and '
                          'opaque FFT setup tables. Input bytes separate. All workers below64MiB.',
            comparison='Same PCM, independent supports/hops, YIN FFT with tracking disabled. '
                       'First/middle/last scalar probes checked against independent oracles outside measurement. '
                       'Strengths are algorithm-specific and are not probabilities.',
            delay='Full observed support/2 relative to midpoint; retain each algorithm support separately.',
            latency='Full Run batch cost, not worst-frame or capture latency. Amortized processing divides '
                    'by full frames; input duration/wall time describes throughput only.',
            allocationClaim='Every prepared non-export Run must have zero heap maxima. OwnedDiagnostics '
                            'allocates by design. Positive allocation/ARC control required; diagnostics disabled.'))
        (output / 'environment.json').write_text(ci.redact(json.dumps(environment, indent=2)) + '\n')
        (output / 'resolution.json').write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ['swift', 'package', *common, '--allow-writing-to-package-directory', 'benchmark',
                  '--target', TARGET, '--time-units', 'nanoseconds', '--no-progress']
        with (output / 'commands.log').open('w') as log:
            def run(command):
                ci.run_command(command, log, result['commands'])
            run([sys.executable, 'Tools/verify-provenance.py'])
            run(['swift', 'build', *common, '--product', 'SWIPEPrimeWorkloadCheck'])
            binary_dir = Path(ci.capture('swift', 'build', *common, '--show-bin-path'))
            matrix = capture_workloads([str(binary_dir / 'SWIPEPrimeWorkloadCheck'), '--shard', args.shard],
                                       log, result['commands'])
            validate_matrix(matrix, args.shard)
            (output / 'workloads.json').write_text(json.dumps(matrix, indent=2, allow_nan=False) + '\n')
            run([sys.executable, 'Tools/SWIPE/probe_audit.py', str(output / 'workloads.json'),
                 '--shard', args.shard, '--output', str(output / 'oracle-probes.json')])
            probes = json.loads((output / 'oracle-probes.json').read_text())
            if probes['status'] != 'passed' or probes['workloadRows'] != len(matrix):
                raise ValueError('Independent scalar probes did not cover the workload matrix')
            names = {benchmark_name(row, operation) for row in matrix for operation in OPERATIONS}
            if args.mode == 'allocation':
                names.add(CONTROL)
            plugin += ['--filter', '^(' + '|'.join(re.escape(n) for n in sorted(names)) + ')$']
            if baseline.exists():
                raise ValueError('Fresh baseline unexpectedly exists')
            run([*plugin, 'baseline', 'update', name])
            raw = json.loads((baseline / 'results.json').read_text())
            if raw.get('baselineName') != name:
                raise ValueError('Raw baseline identity differs from this execution')
            raw['machine']['hostname'] = '<host>'
            with gzip.open(output / 'raw-baseline.json.gz', 'wt') as stream:
                json.dump(raw, stream, separators=(',', ':'), allow_nan=False)
            raw_preserved = True
            summary = validate_raw(raw, matrix, args.mode)
            (output / 'distributions.json').write_text(json.dumps(summary, indent=2) + '\n')
            result['binary'] = smoke.inspect_binary(binary_dir / TARGET, args.mode)
            run([*plugin, 'baseline', 'read', name, '--format', 'jsonSmallerIsBetter', '--path', str(output)])
            exports = json.loads((output / f'{name}.json').read_text())
            values = validate_export(exports, summary, args.mode)
            (output / 'p99.json').write_text(json.dumps(values, indent=2) + '\n')
            (output / f'{name}.json').unlink()
            if source_hashes() != sources:
                raise ValueError('Measurement sources changed during the run')
            result.update(status='passed', workloadCount=len(matrix), oracleProbeCount=probes['probes'],
                          benchmarkCount=len(summary), metricCount=len(values), sourceStable=True,
                          preparedRunAllocationMaximum=0 if args.mode == 'allocation' else None,
                          allocationEvidence='Positive control and zero-heap prepared runs; owned exports '
                          'allocate by design' if args.mode == 'allocation' else 'Instrumentation disabled')
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        result['error'] = ci.redact(str(error))
        print(result['error'], file=sys.stderr)
    finally:
        if baseline.exists() and raw_preserved:
            shutil.rmtree(baseline)
        elif baseline.exists():
            result['unarchivedBaselineRetained'] = ci.redact(str(baseline))
        if lock.read_bytes() != before:
            result.update(status='failed', error='Package.resolved changed during locked measurement')
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
