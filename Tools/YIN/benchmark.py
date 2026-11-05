#!/usr/bin/env python3
"""Measure the A09 YIN matrix, with independent evidence and allocation checks."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import math
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools'))
import ci

SPEC = importlib.util.spec_from_file_location('smoke_benchmark', ROOT / 'Tools/benchmark.py')
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)
SPEC = importlib.util.spec_from_file_location('yin_canonical', ROOT / 'Tools/Reference/common.py')
canonical_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(canonical_module)
PACKAGE = ROOT / 'Benchmarks'
OPERATIONS = ('Prepare', 'Run')
CONTROL = 'Capability.YINAllocationARC'
ALLOCATIONS = ('mallocCountTotal', 'mallocBytesCount', 'objectAllocCount')
DIAGNOSTICS = (*ALLOCATIONS, 'freeCountTotal', 'retainCount', 'releaseCount')
SHARDS = ('rate16000', 'rate44100', 'rate48000', 'float32', 'support', 'long-scalar', 'long-fft', 'export')


def expected_cases(shard=None):
    result = {}
    def add(kind='Harmonic', rate=48000, precision='float64', floor=50, ceiling=700,
            hop=10, backend='fft', tracking=True):
        integration = 16384 if kind == 'MaximumSupport' else math.ceil(rate / floor)
        support = integration + math.ceil(rate / floor) + 1
        hop_samples = (rate * hop + 500) // 1000
        count = support + 3 * hop_samples if kind == 'MaximumSupport' else rate * (30 if kind in ('Silence', 'Noise') else 2)
        name = f'{kind}.{precision}.{rate}Hz.n{count}.f{floor}-{ceiling}.h{hop}.w{integration}.{backend}.track{int(tracking)}'
        group = ('float32' if precision == 'float32' else f'rate{rate}') if kind == 'Harmonic' else 'support' if kind in ('LowFloor','MaximumSupport') else f'long-{backend}' if kind in ('Silence','Noise') else 'export'
        result[name] = dict(kind=kind, rate=rate, precision=precision, floor=floor, ceiling=ceiling,
                            hop=hop, backend=backend, tracking=tracking, integration=integration,
                            support=support, hopSamples=hop_samples, count=count, shard=group)
    for rate in (16000, 44100, 48000):
        for hop in (5, 10):
            for floor, ceiling in ((50,700),(25,2000)):
                for backend in ('scalar','fft'):
                    for tracking in (False,True):
                        add(rate=rate, floor=floor, ceiling=ceiling, hop=hop, backend=backend, tracking=tracking)
                        if rate == 48000: add(rate=rate, precision='float32', floor=floor, ceiling=ceiling, hop=hop, backend=backend, tracking=tracking)
        for backend in ('scalar','fft'): add(kind='LowFloor', rate=rate, floor=25, ceiling=2000, hop=5, backend=backend)
    for backend in ('scalar','fft'):
        add(kind='MaximumSupport', rate=192000, floor=20, ceiling=2000, backend=backend)
        for kind in ('Silence','Noise'):
            for tracking in (False,True): add(kind=kind, floor=25, ceiling=2000, hop=5, backend=backend, tracking=tracking)
    for precision in ('float32','float64'): add(kind='OwnedDiagnostics', precision=precision)
    if shard is not None:
        if shard not in SHARDS: raise ValueError('Unknown YIN shard')
        result = {name: row for name, row in result.items() if row['shard'] == shard}
    return result


def expected_profile(row):
    estimator = dict(schemaVersion=1, sampleRate=row['rate'], inputPrecision=row['precision'],
        arithmeticPrecision='float64', pitchFloorHz=row['floor'], pitchCeilingHz=row['ceiling'],
        integrationLength=row['integration'], hopLength=row['hopSamples'], threshold=.1,
        silenceRMSThreshold=1e-7, differenceBackend=row['backend'], partialWindowPolicy='emitUnavailable',
        definition='hdxl-yin-fixed-time-2002-steps2to5', interpolation='cmndOrdinateRawDifferencePeriod',
        supportPolicy='fixedIntegrationPlusMaximumLagAndNeighbor', normalization='observedPeak',
        neighboringTimeRefinement='disabled', rangeBoundaryToleranceSamples=2e-6)
    tracker = dict(schemaVersion=1, definition='causal-yin-candidate-continuity', continuityWeight=.05) if row['tracking'] else None
    return dict(schemaVersion=1, estimator=estimator, tracker=tracker)


def identity(value, family):
    return dict(identifier=dict(name=family, version=1), sha256=hashlib.sha256(canonical_module.canonical(value)).hexdigest())


def validate_matrix(matrix, shard=None):
    expected = expected_cases(shard)
    seen, hashes = set(), {}
    for record in matrix:
        name = record['name']
        if name not in expected or name in seen: raise ValueError('Missing, extra or duplicate YIN case')
        seen.add(name)
        row = expected[name]; profile = expected_profile(row); c = profile['estimator']
        rate, count, support, hop = (row[x] for x in ('rate','count','support','hopSamples'))
        stride = 4 if row['precision'] == 'float32' else 8
        hi = math.ceil(rate / row['floor']); lo = math.floor(rate / row['ceiling'])
        lag_count = hi + 2
        fft = 1 << (support + row['integration'] - 2).bit_length() if row['backend'] == 'fft' else 0
        workspace = (support + 2 * lag_count) * 8 + (hi - lo + 1) * 56 + 3 * support * stride
        if fft: workspace += (row['integration'] + support + 1 + 3 * fft) * 8 + 2 * (fft // 2 + 1) * 16
        workload = dict(name=name, kind=row['kind'], profile=profile, requestedHopMilliseconds=row['hop'],
                        inputSampleCount=count, chunkSamples=256)
        if record['workload'] != workload: raise ValueError('Incorrect YIN workload/profile recipe')
        geometry = dict(inputDurationSeconds=count/rate, preparedInputBytes=count*stride,
            preparedBufferBytes=workspace, candidateRecordStride=56, fftLength=fft,
            integrationLength=row['integration'], supportSamples=support, hopSamples=hop,
            supportDurationSeconds=support/rate, algorithmicDelaySeconds=support/rate/2,
            maximumRawDelaySeconds=support/rate/2)
        if any(record[k] != v for k,v in geometry.items()): raise ValueError('Incorrect YIN geometry/storage/delay')
        identities = dict(profileIdentity=identity(profile,'yin-estimator-and-optional-tracker'),
                          estimatorIdentity=identity(c,c['definition']),
                          trackerIdentity=identity(profile['tracker'],profile['tracker']['definition']) if profile['tracker'] else None)
        if any(record.get(k) != v for k,v in identities.items()): raise ValueError('Incorrect YIN profile fingerprint')
        digest = record['inputSHA256']
        if not isinstance(digest,str) or re.fullmatch('[a-f0-9]{64}',digest) is None: raise ValueError('Missing PCM identity')
        kind = 'Harmonic' if row['kind'] == 'OwnedDiagnostics' else row['kind']
        key = kind, rate, row['precision'], count
        if key in hashes and hashes[key] != digest: raise ValueError('Inconsistent identical PCM hashes')
        hashes[key] = digest
        full = (count-support)//hop+1; partial = int(full*hop < count); total = full+partial
        exact = dict(fullFrames=full, partialFrames=partial, emittedFrames=total, trackedFrames=total if row['tracking'] else 0)
        if any(record[k] != v for k,v in exact.items()): raise ValueError('Incorrect full/partial/tracked coverage')
        keys = ('voicedFrames','uncertainFrames','unvoicedFrames','unavailableFrames')
        if any(type(record[k]) is not int or record[k]<0 for k in keys) or sum(record[k] for k in keys)!=total or record['unavailableFrames']<partial:
            raise ValueError('Incorrect availability denominators')
        if kind == 'Harmonic' and record['voicedFrames'] != full: raise ValueError('Harmonic signal lost coverage')
        if kind == 'Silence' and record['unvoicedFrames'] != full: raise ValueError('Silence produced pitch')
        if kind == 'Noise' and record['voicedFrames'] != 0: raise ValueError('Noise produced voiced estimate')
        if type(record['changedSelections']) is not int or not 0 <= record['changedSelections'] <= (record['voicedFrames'] if row['tracking'] else 0):
            raise ValueError('Invalid tracked selection count')
        delay = record['maximumDependencyDelaySeconds']
        if not isinstance(delay,(int,float)) or not math.isfinite(delay) or (not support/rate/2 <= delay <= max(count/rate/2,support/rate/2)+1e-12 if row['tracking'] else delay != 0):
            raise ValueError('Invalid tracking dependency delay')
        for key, maximum in (('directlyRecomputedLags', full*(hi+1)), ('scalarFallbackFrames',full)):
            value = record[key]
            if type(value) is not int or not 0 <= value <= maximum or (not fft and value != 0):
                raise ValueError('Invalid backend diagnostic counter')
        exporting = row['kind'] == 'OwnedDiagnostics'
        if record['exportedScalars'] != (2*full*lag_count if exporting else 0): raise ValueError('Incorrect curve export coverage')
        for key in ('exportedCandidates','exportedJSONBytes','exportedByteChecksum'):
            value = record[key]
            if type(value) is not int or (value <= 0 if exporting else value != 0): raise ValueError('Incorrect owned export evidence')
        if not isinstance(record['checksum'],(int,float)) or not math.isfinite(record['checksum']) or record['checksum']<=0:
            raise ValueError('Missing observable result checksum')
    if seen != set(expected): raise ValueError('Missing YIN matrix coverage')
    return matrix


def validate_raw(raw, matrix, mode):
    expected = {f"YIN.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    if mode == "allocation":
        expected.add(CONTROL)
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra raw benchmark distributions")
    allocating_runs = {f"YIN.Run.{r['name']}" for r in matrix
                       if r['workload']['kind'] in ('OwnedDiagnostics',)}
    result = {}
    required = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "YINBenchmarks":
            raise ValueError("Unexpected/duplicate yin workload")
        metrics = {}
        for measurement in measurements:
            if len(measurement["metric"]) != 1 or measurement["scalingFactor"] != 1:
                raise ValueError("Unexpected metric identity or framework scaling")
            metric = next(iter(measurement["metric"]))
            histogram = measurement["statistics"]["histogram"]
            count = histogram["_totalCount"]
            maximum = histogram["maxValue"]
            if metric in metrics or metric not in required or type(count) is not int or count < 10:
                raise ValueError("Missing/duplicate metric or fewer than 10 measured samples")
            buckets = histogram["counts"]
            if (type(maximum) is not int or maximum < 0 or not isinstance(buckets, list)
                    or not buckets or any(type(v) is not int or v < 0 for v in buckets)
                    or sum(buckets) != count):
                raise ValueError("Malformed histogram evidence")
            if metric == "wallClock" and maximum <= 0:
                raise ValueError("No positive workload duration")
            if mode == "allocation":
                if name == CONTROL and metric in DIAGNOSTICS and maximum <= 0:
                    raise ValueError(f"Unavailable allocation/ARC capability: {metric}")
                if name.startswith("YIN.Run.") and name not in allocating_runs and metric in ALLOCATIONS and maximum != 0:
                    raise ValueError(f"Steady-state allocation observed: {name}, {metric}, maximum={maximum}")
            metrics[metric] = {"sampleCount": count, "maximum": maximum}
        if set(metrics) != required:
            raise ValueError("Missing metric coverage")
        result[name] = metrics
    return result


def validate_export(rows, names, mode):
    metrics = ("Time (wall clock)", "Time (total CPU)") if mode == "timing" else ("Time (wall clock)", *smoke.DIAGNOSTICS)
    expected = {f"{name} - {metric}" for name in names for metric in metrics}
    result = {}
    for row in rows:
        name, value = row["name"], row["value"]
        if name not in expected or name in result or isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0:
            raise ValueError("Invalid p99 benchmark export")
        wanted_unit = "ns" if " - Time (" in name else "#"
        if row["unit"] != wanted_unit:
            raise ValueError("Unexpected benchmark unit")
        result[name] = value
    if set(result) != expected:
        raise ValueError("Missing p99 export metrics")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("timing", "allocation"))
    parser.add_argument("--shard", choices=SHARDS, required=True)
    args = parser.parse_args()
    output = PACKAGE / ".build/artifacts" / f"yin-{args.mode}-{args.shard}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "shard": args.shard, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"yin-{args.mode}-{args.shard}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/YINBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "A09 YIN raw/tracked PCM analysis, actual low-F0 support, long silence/noise, and owned diagnostics; physical evidence deferred #74",
                            "mode": args.mode, "shard": args.shard, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, one declared Prepare or Run operation",
                            "sampling": "Run: one warmup, ten measured operations, 3600s cap. Prepare/control: three warmups, thirty measured operations, 60s cap. Ten samples required; p99 of ten is effectively the maximum, not a stable population tail estimate.",
                            "distributions": "raw-baseline.json.gz; sample counts/maxima in distributions.json; p99.json",
                            "input": "Original 125/250/375Hz harmonic PCM (amplitudes .4/.1/.04, second phase .13); low-floor pure sine amplitude .5 at configured floor; silence; UInt32 LCG seed38 noise. Round once to declared source precision. Generation excluded; exact input bytes hashed.",
                            "operations": {"Prepare": "construct/destroy streaming estimator, framer and optional tracker; input generation excluded",
                                           "Run": "reset, process entire prepared input in 256-sample chunks, consume raw/tracked scalar outputs, finalize one partial tail. OwnedDiagnostics additionally copies candidates/both curves and serializes both raw/tracked measurements, consuming every encoded byte; it includes DSP, not isolated serialization."},
                            "workingMemory": "owned estimator/framer/FFT/candidate buffers; excludes small value tracker state, object bookkeeping and opaque FFT setup tables. Input bytes separate. No duration-growing worker PCM or tracker arrays.",
                            "delay": "raw full observed support / 2 relative to midpoint; tracking has zero extra lookahead but a wider history dependency interval. Maximum dependency-coordinate delay reported separately. No physical capture latency claim.",
                            "latency": "full Run batch cost, not worst individual frame or capture latency. Divide by full frame count only for amortized processing; input duration / wall time is throughput.",
                            "allocationClaim": "All prepared non-export Run heap maxima must be zero. OwnedDiagnostics allocates by design. Positive allocation/ARC control required; diagnostics disabled."})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "YINBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "YINWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "YINWorkloadCheck"), "--shard", args.shard))
            validate_matrix(matrix, args.shard)
            names = "|".join(re.escape(row["name"]) for row in matrix)
            plugin += ["--filter", rf"^(YIN\.(Prepare|Run)\.({names})|{re.escape(CONTROL)})$"]
            (output / "workloads.json").write_text(json.dumps(matrix, indent=2) + "\n")
            if baseline.exists():
                raise ValueError("Fresh baseline unexpectedly exists")
            run([*plugin, "baseline", "update", name])
            raw = json.loads((baseline / "results.json").read_text())
            if raw.get("baselineName") != name:
                raise ValueError("Raw capture identity differs from this execution")
            raw["machine"]["hostname"] = "<host>"
            with gzip.open(output / "raw-baseline.json.gz", "wt") as stream:
                json.dump(raw, stream, separators=(",", ":"), allow_nan=False)
            summary = validate_raw(raw, matrix, args.mode)
            (output / "distributions.json").write_text(json.dumps(summary, indent=2) + "\n")
            result["binary"] = smoke.inspect_binary(binary_dir / "YINBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "preparedRunAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus zero-heap prepared YIN processing, with owned export allocations reported separately" if args.mode == "allocation" else "instrumentation disabled"})
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        result["error"] = ci.redact(str(error))
        print(result["error"], file=sys.stderr)
    finally:
        if baseline.exists():
            shutil.rmtree(baseline)
        if lock.read_bytes() != before:
            result.update(status="failed", error="Package.resolved changed during locked measurement")
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
