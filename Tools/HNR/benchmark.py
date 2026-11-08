#!/usr/bin/env python3
"""Measure the A11 HNR matrix, with independent evidence and allocation checks."""
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
SPEC = importlib.util.spec_from_file_location('hnr_canonical', ROOT / 'Tools/Reference/common.py')
canonical_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(canonical_module)
PACKAGE = ROOT / 'Benchmarks'
OPERATIONS = ('Prepare', 'Run')
CONTROL = 'Capability.HNRAllocationARC'
ALLOCATIONS = ('mallocCountTotal', 'mallocBytesCount', 'objectAllocCount')
DIAGNOSTICS = (*ALLOCATIONS, 'freeCountTotal', 'retainCount', 'releaseCount')
SHARDS = ('ac16000', 'ac44100', 'ac48000', 'cc16000', 'cc44100', 'cc48000', 'stress', 'export')


def capture_stdout(*command):
    # SwiftPM lock-wait notices are stderr, and can lack a trailing newline.
    # Keep them out of machine-readable paths/JSON rather than parsing mixed text.
    return subprocess.run(command,cwd=ROOT,text=True,capture_output=True,check=True).stdout.strip()


def expected_cases(shard=None):
    result = {}
    def add(kind='Harmonic', method='ac', rate=48000, precision='float64', periods=4.5,
            floor=75, hop=10, normalization='causal'):
        effective = periods * (2 if method == 'ac' else 1)
        width = effective / floor
        support = width + (1 / floor if method == 'cc' else 0)
        window = 2 * (math.floor(width / (1 / rate)) // 2 - 1)
        causal = math.ceil(support * rate)
        count = causal + 3 * (rate * hop // 1000) if kind == 'LowFloor' else rate * 5 if kind in ('Silence', 'Noise') else rate * 2 // 5
        name = f'{kind}.{method}.{precision}.{rate}Hz.p{periods:.1f}.f{floor}.h{hop}.{normalization}'
        result[name] = dict(kind=kind, method=method, rate=rate, precision=precision,
            periods=periods, floor=floor, hop=hop, normalization=normalization,
            effective=effective, window=window, support=support, causal=causal, count=count,
            shard=f'{method}{rate}' if kind=='Harmonic' else 'export' if kind=='OwnedDiagnostics' else 'stress')
    for method in ('ac','cc'):
        for rate in (16000,44100,48000):
            for periods in (4.5,6.):
                for floor in (60,75):
                    for hop in (5,10):
                        for precision in ('float32','float64'):
                            for normalization in ('whole','causal'):
                                add(method=method,rate=rate,periods=periods,floor=floor,hop=hop,
                                    precision=precision,normalization=normalization)
        for precision in ('float32','float64'):
            add(kind='LowFloor',method=method,precision=precision,periods=6.,floor=20,hop=5)
            for normalization in ('whole','causal'):
                add(kind='OwnedDiagnostics',method=method,precision=precision,normalization=normalization)
        for kind in ('Silence','Noise'): add(kind=kind,method=method,periods=6.,floor=60,hop=5)
    if shard is not None:
        if shard not in SHARDS: raise ValueError('Unknown HNR shard')
        result = {name:row for name,row in result.items() if row['shard']==shard}
    return result


def expected_profile(row):
    return dict(schemaVersion=1,method=row['method'],sampleRate=row['rate'],inputPrecision=row['precision'],
        arithmeticPrecision='float64',pitchFloorHz=row['floor'],periodsPerWindow=row['periods'],
        hopSeconds=row['hop']/1000,silenceThreshold=.1,
        normalization='wholeIntervalMeanRemovedPeak' if row['normalization']=='whole' else 'causalWindowMeanRemovedPeak',
        window='pitchGaussianNPlusOne' if row['method']=='ac' else 'rectangularForwardPair',
        interpolation='sinc700SymmetricRaisedCosineDepthPlusHalf',overshoot='reciprocalAboveOne',
        peakResolution='positiveLocalMaximumCurvature128Binary64Ulps-v1',minimumPeakCurvature=128*math.ulp(1.),
        reportingPeriodicityLimit=1e-15,reportingDecibelLimit=150,
        frameGrid='centeredWholeIntervalBinary64FusedStep' if row['normalization']=='whole' else 'causalAcquiredWindowCenterExactBinary64StepAccumulator',
        arithmeticScaling='framePeakScaledBinary64WithSeparateSilenceReference',partialWindowPolicy='emitUnavailable')


def validate_matrix(matrix, shard=None):
    from fractions import Fraction
    expected = expected_cases(shard)
    seen, hashes = set(), {}
    for record in matrix:
        name = record['name']
        if name not in expected or name in seen: raise ValueError('Missing, extra or duplicate HNR case')
        seen.add(name)
        row=expected[name]; c=expected_profile(row)
        rate,count,n=(row[k] for k in ('rate','count','window'))
        ac=row['method']=='ac'; whole=row['normalization']=='whole'
        lag=min(math.floor(n/row['effective'])+2,n); radius=n//4 if ac else n
        fft=1 << ((n+radius if ac else 2*n+lag-1)-1).bit_length()
        stride=4 if row['precision']=='float32' else 8
        candidate_stride=152
        capacity=max(15,math.floor((rate/2)/row['floor']))-1
        # The six scalar correlation arrays, validity, two spectra and FFT scratch;
        # then frame window/forward scratch, bounded candidate/retention records.
        workspace=(n+(3 if ac else 1)*(radius+1)+(0 if ac else n)+fft)*8
        workspace+=(radius+1)+2*(fft//2+1)*16+2*fft*8
        workspace+=(n+(0 if ac else n+lag))*8+min(lag,radius)*candidate_stride+capacity*8
        workspace+=(count if whole else 2*row['causal'])*stride
        duration=(1/rate)*count
        if whole:
            full=0 if duration<row['support'] else math.floor((duration-row['support'])/c['hopSeconds'])+1
            partial=0
        else:
            step=Fraction.from_float(c['hopSeconds']*rate)
            full=0
            while (full*step).__floor__()+row['causal']<=count: full+=1
            partial=int((full*step).__floor__()<count)
        norm=count if whole else row['causal']
        workload=dict(name=name,kind=row['kind'],configuration=c,inputSampleCount=count,chunkSamples=256)
        if canonical_module.canonical(record['workload'])!=canonical_module.canonical(workload): raise ValueError('Incorrect HNR workload/profile recipe')
        geometry=dict(inputDurationSeconds=count/rate,preparedInputBytes=count*stride,
            preparedBufferBytes=workspace,candidateRecordStride=candidate_stride,transformLength=fft,
            windowSamples=n,maximumCandidateLag=lag,maximumCorrelationLag=radius,
            normalizationWindowSamples=norm,nominalSupportSeconds=row['support'],hopSamples=c['hopSeconds']*rate,
            maximumDependencyDelaySeconds=(norm/rate)/2,
            emittedFrames=full+partial,completeFrames=full,partialFrames=partial)
        if any(record[k]!=v or isinstance(record[k],bool) for k,v in geometry.items()):
            mismatches={k:(record[k],v) for k,v in geometry.items() if record[k]!=v}
            raise ValueError(f'Incorrect HNR geometry/storage/delay: {mismatches}')
        identity=dict(identifier=dict(name=f"hdxl-hnr-{row['method']}-{c['normalization']}",version=1),
            sha256=hashlib.sha256(canonical_module.canonical(c)).hexdigest())
        if record['profileIdentity']!=identity: raise ValueError('Incorrect HNR profile fingerprint')
        digest=record['inputSHA256']
        if not isinstance(digest,str) or re.fullmatch('[a-f0-9]{64}',digest) is None: raise ValueError('Missing PCM identity')
        kind='Harmonic' if row['kind']=='OwnedDiagnostics' else row['kind']
        key=kind,rate,row['precision'],count
        if key in hashes and hashes[key]!=digest: raise ValueError('Inconsistent identical PCM hashes')
        hashes[key]=digest
        for k in ('availableFrames','finiteFrames','unavailableFrames','reportingLimitFrames','numericalZeroNoiseFrames'):
            if type(record[k]) is not int or not 0<=record[k]<=full+partial: raise ValueError('Invalid HNR coverage')
        available=record['availableFrames']; unity=record['numericalZeroNoiseFrames']
        if available+record['unavailableFrames']!=full+partial or record['finiteFrames']+unity!=available or not unity<=record['reportingLimitFrames']<=available:
            raise ValueError('Invalid HNR denominators')
        if kind=='Harmonic' and available!=full: raise ValueError('Harmonic signal lost coverage')
        if kind=='Silence' and available!=0: raise ValueError('Silence produced HNR')
        exporting=row['kind']=='OwnedDiagnostics'
        scalars=full*(n+(3 if ac else 1)*(radius+1)) if exporting else 0
        if record['exportedScalars']!=scalars: raise ValueError('Incorrect owned curve export coverage')
        for k in ('exportedCandidates','exportedJSONBytes','exportedByteChecksum'):
            value=record[k]
            if type(value) is not int or (value<=0 if exporting else value!=0): raise ValueError('Incorrect owned export evidence')
        if type(record['checksum']) not in (int,float) or not math.isfinite(record['checksum']) or record['checksum']<=0:
            raise ValueError('Missing observable result checksum')
    if seen!=set(expected): raise ValueError('Missing HNR matrix coverage')
    return matrix


def validate_raw(raw, matrix, mode):
    expected = {f"HNR.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    if mode == "allocation":
        expected.add(CONTROL)
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra raw benchmark distributions")
    allocating_runs = {f"HNR.Run.{r['name']}" for r in matrix
                       if r['workload']['kind'] in ('OwnedDiagnostics',)}
    result = {}
    required = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "HNRBenchmarks":
            raise ValueError("Unexpected/duplicate hnr workload")
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
                if name.startswith("HNR.Run.") and name not in allocating_runs and metric in ALLOCATIONS and maximum != 0:
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
    output = PACKAGE / ".build/artifacts" / f"hnr-{args.mode}-{args.shard}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "shard": args.shard, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"hnr-{args.mode}-{args.shard}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/HNRBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "A11 AC/CC HNR, whole and causal normalization, requested 48-profile matrix in both input precisions, low-F0 support, long silence/noise and owned diagnostics; physical evidence deferred #74",
                            "mode": args.mode, "shard": args.shard, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, one declared Prepare or Run operation",
                            "sampling": "Run: one warmup, ten measured operations, 3600s cap. Prepare/control: three warmups, thirty measured operations, 60s cap. Ten samples required; p99 of ten is effectively the maximum, not a stable population tail estimate.",
                            "distributions": "raw-baseline.json.gz; sample counts/maxima in distributions.json; p99.json",
                            "input": "Original 120/240Hz harmonic PCM (.4/.08) plus .015 times UInt32 LCG seed39 noise; low-floor uses configured floor and its octave; silence; pure LCG noise. Round once to declared source precision. Generation excluded; exact input bytes hashed.",
                            "operations": {"Prepare": "construct/destroy selected whole-interval or causal HNR worker, normalization storage and FFT; input generation excluded",
                                           "Run": "reset, append/process entire prepared input in 256-sample chunks and finish. Includes normalization, window preparation, correlation, internal period search and scalar consumption. Whole-interval grid has no partial slot; causal has one acquired partial tail. OwnedDiagnostics also copies candidates/window/correlation arrays and serializes every measurement, consuming every encoded byte; includes DSP, not isolated serialization."},
                            "workingMemory": "owned worker PCM, window/correlation/candidate/FFT buffers; excludes object bookkeeping and opaque FFT setup tables. Input bytes separate. Whole mode retains its explicitly bounded full input; causal has fixed ring/emission buffers. No transform sharing with other algorithms.",
                            "delay": "normalization dependency duration / 2 relative to midpoint, separate from processing cost. Whole interval depends on complete input; causal depends on current acquired window. No physical capture latency claim.",
                            "latency": "full Run batch cost, not worst individual frame or capture latency. Divide by full frame count only for amortized processing; input duration / wall time is throughput.",
                            "allocationClaim": "All prepared non-export Run heap maxima must be zero. OwnedDiagnostics allocates by design. Positive allocation/ARC control required; diagnostics disabled."})
        environment["sourceSHA256"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted([*ROOT.glob("Sources/HDXLVoiceProcessing/**/*.swift"),
                ROOT/"Benchmarks/Sources/HNRWorkload/HNRWorkload.swift",
                ROOT/"Benchmarks/Benchmarks/HNRBenchmarks/HNRBenchmarks.swift", Path(__file__)])}
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "HNRBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "HNRWorkloadCheck"])
            binary_dir = Path(capture_stdout("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(capture_stdout(str(binary_dir / "HNRWorkloadCheck"), "--shard", args.shard))
            validate_matrix(matrix, args.shard)
            names = "|".join(re.escape(row["name"]) for row in matrix)
            plugin += ["--filter", rf"^(HNR\.(Prepare|Run)\.({names})|{re.escape(CONTROL)})$"]
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
            result["binary"] = smoke.inspect_binary(binary_dir / "HNRBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "preparedRunAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus zero-heap prepared HNR processing, with owned export allocations reported separately" if args.mode == "allocation" else "instrumentation disabled"})
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
