#!/usr/bin/env python3
"""Measure the A07 CPPS matrix with fresh distributions and verified allocation controls."""
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
sys.path.insert(0, str(ROOT / "Tools"))
import ci

SPEC = importlib.util.spec_from_file_location("smoke_benchmark", ROOT / "Tools/benchmark.py")
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)
CANONICAL_SPEC = importlib.util.spec_from_file_location("cpps_benchmark_canonical", ROOT / "Tools/Reference/common.py")
canonical_module = importlib.util.module_from_spec(CANONICAL_SPEC)
CANONICAL_SPEC.loader.exec_module(canonical_module)
PACKAGE = ROOT / "Benchmarks"
OPERATIONS = ("Prepare", "Run")
CONTROL = "Capability.CPPSAllocationARC"
ALLOCATIONS = ("mallocCountTotal", "mallocBytesCount", "objectAllocCount")
DIAGNOSTICS = (*ALLOCATIONS, "freeCountTotal", "retainCount", "releaseCount")


SHARDS = tuple(f'h{hop}-w{window}' for hop in (2, 5, 10, 30) for window in (1, 3, 5)) + ('variants',)


def expected_cases(shard=None):
    result = {}
    def add(kind='PreviewCPPS', precision='float64', rate=16000, hop=10, time=10,
            quefrency=1, window=3, pretrend=False, primary=False):
        name = f'{kind}.{precision}.{rate}Hz.6s.h{hop}.t{time}.q{quefrency}.w{window}.pre{int(pretrend)}'
        result[name] = dict(kind=kind, precision=precision, rate=rate, hop=hop, time=time,
                            quefrency=quefrency, window=window, pretrend=pretrend,
                            shard=f'h{hop}-w{window}' if primary else 'variants')
    for hop in (2, 5, 10, 30):
        for time in (10, 20, 50):
            for quefrency in (1, 5):
                for window in (1, 3, 5):
                    add(hop=hop, time=time, quefrency=quefrency, window=window, primary=True)
    for precision, rate in (('float32', 16000), ('float32', 48000), ('float64', 48000)):
        for window in (1, 5): add(precision=precision, rate=rate, time=20, window=window)
    for precision in ('float32', 'float64'):
        for rate in (16000, 48000): add(kind='IntervalCPPS', precision=precision, rate=rate, hop=2)
    for window in (2, 4): add(time=20, window=window)
    add(pretrend=True)
    add(kind='OwnedDiagnostics')
    add(kind='OwnedDiagnostics', pretrend=True)
    if shard is not None:
        if shard not in SHARDS: raise ValueError('Unknown CPPS shard')
        result = {name: row for name, row in result.items() if row['shard'] == shard}
    return result


def is_digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def expected_profile(row):
    rate, precision, hop = row['rate'], row['precision'], row['hop']
    preview = row['kind'] != 'IntervalCPPS'
    phases = 10000 // math.gcd(rate, 10000)
    frame = {'schemaVersion': 1, 'definition': 'praat-7.0.02-power-cepstrum',
             'sampleRate': 10000, 'precision': 'float64', 'pitchFloorHz': 60,
             'frameLength': 1000, 'transformLength': 1024}
    conditioning = {'schemaVersion': 1, 'sourceSampleRate': rate, 'targetSampleRate': 10000,
        'precision': 'float64', 'ratio': {'numerator': phases, 'denominator': rate // math.gcd(rate, 10000)},
        'method': {'kind': 'streamingPreview', 'lobes': 16, 'cutoffFraction': 0.9} if preview else
                  {'kind': 'praat7WholeInterval', 'interpolationDepth': 50},
        'preEmphasisFromHz': None, 'declaredInputBandwidthHz': rate / 2,
        'requiredInputBandwidthHz': 5000, 'gainPolicy': 'none'}
    config = {'schemaVersion': 1, 'inputPrecision': precision, 'frame': frame,
        'conditioning': conditioning, 'hopSeconds': hop / 1000, 'preEmphasisFromHz': 50,
        'previewHopLength': hop * 10 if preview else None}
    cpp = {'schemaVersion': 1, 'pitchFloorHz': 60, 'pitchCeilingHz': 330,
           'interpolation': 'parabolic', 'fitStartSeconds': .001, 'fitEndSeconds': 0, 'fitMethod': 'praat7002Robust'}
    return {'schemaVersion': 1, 'cepstrogram': config, 'settings': {
        'schemaVersion': 1, 'definition': 'praat7002InterpolatedPower', 'edgePolicy': 'normalizeAvailableSupport',
        'timeWindowSeconds': row['time'] / 1000, 'quefrencyWindowSeconds': row['quefrency'] / 1000,
        'subtractTrendBeforeSmoothing': row['pretrend'], 'pitchTolerance': .05, 'prominence': cpp}}


def validate_matrix(matrix, shard=None):
    expected = expected_cases(shard)
    seen, input_hashes, measurement_hashes, statistic_hashes = set(), {}, {}, set()
    record_strides = {}
    for record in matrix:
        name = record['name']
        if name not in expected or name in seen: raise ValueError('Missing, extra, or duplicate CPPS case')
        seen.add(name)
        row = expected[name]; item = record['workload']
        kind, precision, rate, hop, time, window = (row[k] for k in ('kind', 'precision', 'rate', 'hop', 'time', 'window'))
        preview = kind != 'IntervalCPPS'
        profile = expected_profile(row)
        statistic = {'schemaVersion': 1, 'measurement': profile, 'population': 'allEligible',
            'selection': {'selectionSources': [], 'combination': 'all', 'rejectedTags': []},
            'provenances': [], 'aggregation': 'rollingFrameMean', 'rollingWindowSeconds': window}
        if (item['name'], item['kind'], item['shard'], item['inputSampleCount'], item['inputChunkSamples'], item['inputDurationSeconds']) != (name, kind, row['shard'], rate * 6, 256, 6):
            raise ValueError('Unexpected workload geometry')
        if item['profile'] != profile or item['statistic'] != statistic:
            raise ValueError('Incorrect numerical recipe, precision, or statistic binding')
        identity = item['profileIdentity']; aggregate = item['statisticIdentity']
        family = 'finite-fir-preview-cpps' if preview else 'praat-7.0.02-cpps'
        if identity['identifier'] != {'name': family, 'version': 1} or not is_digest(identity['sha256']):
            raise ValueError('Missing/incorrect measurement identity')
        if aggregate['identifier'] != {'name': 'cpps-allEligible-rollingFrameMean', 'version': 1} or not is_digest(aggregate['sha256']):
            raise ValueError('Missing/incorrect statistic identity')
        if identity['sha256'] != hashlib.sha256(canonical_module.canonical(profile)).hexdigest():
            raise ValueError('Measurement identity does not hash the complete recipe')
        if aggregate['sha256'] != hashlib.sha256(canonical_module.canonical(statistic)).hexdigest():
            raise ValueError('Statistic identity does not hash the complete recipe')
        # Export and rolling-window changes leave the underlying CPPS recipe alone.
        key = json.dumps(profile, sort_keys=True)
        if key in measurement_hashes and measurement_hashes[key] != identity['sha256']:
            raise ValueError('Inconsistent measurement identity')
        measurement_hashes[key] = identity['sha256']
        statistic_hashes.add((json.dumps(statistic, sort_keys=True), aggregate['sha256']))
        digest = record['inputSHA256']; input_key = precision, rate
        if not is_digest(digest): raise ValueError('Missing input identity')
        if input_key in input_hashes and input_hashes[input_key] != digest:
            raise ValueError('Identical signals have inconsistent input hashes')
        input_hashes[input_key] = digest
        radius = math.ceil(time / (2 * hop)) if math.floor((time / 1000) / (hop / 1000)) > 1 else 0
        capacity = 2 * radius + 1
        rolling_capacity = math.ceil(window / (hop / 1000)) + 2
        smoothing_bytes = 8 * (2 * capacity * 513 + 2 * 513) + 2 * 8 * (3 * 513 + 3 * 512)
        phases = 10000 // math.gcd(rate, 10000)
        widening = 32768 if precision == 'float32' else 0
        if preview:
            frames, tail = 59000 // (hop * 10) + 1, 1
            width = 2 * math.ceil(16 / (10000 / rate)) + 1
            upstream = (phases * width + 2 * width + 256 + 3000 + 256) * 8 + 73600 + widening
        else:
            frames, tail = math.floor((60000 * .0001 - .1) / (hop / 1000)) + 1, 0
            fft = 1 << (rate * 6 + 1999).bit_length()
            upstream = (rate * 6 + 60000 + 4 * fft + 2 + 100 * phases + 100 + 1000) * 8 + 73600 + widening
        wanted = {'preparedInputBytes': rate * 6 * (4 if precision == 'float32' else 8),
            'preparedScalarBytes': upstream + smoothing_bytes, 'smoothingScalarBytes': smoothing_bytes,
            'smoothingFrameCapacity': capacity, 'rollingFrameCapacity': rolling_capacity,
            'fitPointCount': 512, 'slopeEvaluationsPerFit': 261121, 'smoothingLookaheadFrames': radius,
            'emittedFrameCount': frames + tail, 'availableFrameCount': frames, 'unavailableFrameCount': tail,
            'exportedScalarCount': frames * 7 * 513 if kind == 'OwnedDiagnostics' else 0,
            'verificationChunkSamples': 63}
        for key, value in wanted.items():
            if type(record[key]) is not int or record[key] != value:
                raise ValueError(f'Incorrect workspace/output coverage: {name}, {key}, {record[key]} != {value}')
        if record['smoothingLookaheadSeconds'] != radius * (hop / 1000):
            raise ValueError('Incorrect centered lookahead')
        for key, count in [('smoothingRecordBytes', capacity), ('rollingRecordBytes', rolling_capacity)]:
            value = record[key]
            if type(value) is not int or value <= 0 or value % count:
                raise ValueError('Incorrect bounded record memory')
            stride = value // count
            if key in record_strides and record_strides[key] != stride:
                raise ValueError('Inconsistent record stride')
            record_strides[key] = stride
        for key, limit in [('rollingAvailableQueryCount', frames), ('maximumContributingFrameCount', rolling_capacity)]:
            if type(record[key]) is not int or not 0 < record[key] <= limit:
                raise ValueError('Missing bounded rolling output')
        for key in ('maximumReportedDelaySeconds', 'verificationMaximumReportedDelaySeconds'):
            delay = record[key]
            if type(delay) not in (int, float) or not math.isfinite(delay) or delay < radius * hop / 1000 or delay > 6:
                raise ValueError('Missing/invalid algorithmic delay')
        if type(record['checksum']) not in (int, float) or not math.isfinite(record['checksum']) or record['checksum'] == 0:
            raise ValueError('Missing finite observable output checksum')
    if seen != set(expected): raise ValueError('Missing CPPS matrix coverage')
    if len({k for k, v in statistic_hashes}) != len({v for k, v in statistic_hashes}):
        raise ValueError('Inconsistent statistic identities')
    if len(set(measurement_hashes.values())) != len(measurement_hashes):
        raise ValueError('Different measurement recipes share an identity')
    return matrix


def validate_raw(raw, matrix, mode):
    expected = {f"CPPS.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    if mode == "allocation":
        expected.add(CONTROL)
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra raw benchmark distributions")
    allocating_runs = {f"CPPS.Run.{r['name']}" for r in matrix
                       if r['workload']['kind'] == 'OwnedDiagnostics'}
    result = {}
    required = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "CPPSBenchmarks":
            raise ValueError("Unexpected/duplicate CPPS workload")
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
            if type(maximum) is not int or maximum < 0 or sum(histogram["counts"]) != count:
                raise ValueError("Malformed histogram evidence")
            if metric == "wallClock" and maximum <= 0:
                raise ValueError("No positive workload duration")
            if mode == "allocation":
                if name == CONTROL and metric in DIAGNOSTICS and maximum <= 0:
                    raise ValueError(f"Unavailable allocation/ARC capability: {metric}")
                if name.startswith("CPPS.Run.") and name not in allocating_runs and metric in ALLOCATIONS and maximum != 0:
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
    output = PACKAGE / ".build/artifacts" / f"cpps-{args.mode}-{args.shard}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "shard": args.shard, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"cpps-{args.mode}-{args.shard}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/CPPSBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "A07 full PCM-to-CPPS, bounded source-clock rolling means, and owned diagnostics; physical evidence deferred under #74",
                            "mode": args.mode, "shard": args.shard, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, one declared Prepare or Run operation",
                            "sampling": "Every 6s Run: one warmup, ten measured operations, 3600s cap. Prepare: three warmups, thirty measured operations, 60s cap. Validation requires at least ten samples; p99 of ten samples is effectively the maximum, not a stable population tail estimate.",
                            "distributions": "raw-baseline.json.gz; sample counts and maxima in distributions.json; p99.json",
                            "input": "Six-second original 125/250Hz harmonics plus UInt32 LCG seed37 noise, rounded once to source precision; generated outside measurement, exact bytes hashed.",
                            "operations": {"Prepare": "construct and destroy CPPS/CPP/FFT/conditioning/rolling workspaces, identities, and two immutable all-eligible source masks; input generation excluded",
                                           "Run": "one complete 6s PCM-to-CPPS plus per-frame rolling append/query and raw/final scalar checksum; reset/finalize included; alternate two prepared independent source IDs to exercise new-source reset without mask rebuilding; OwnedDiagnostics also copies all seven stages and shared frame/rolling results"},
                            "workingMemory": "workloads.json reports smoothing and rolling ring capacities, owned scalar and record bytes including two robust fit workspaces, FFT scratch and Float widening; opaque FFT tables/object/mask overhead excluded; prepared PCM separate",
                            "delay": "whole-input analysis waits until interval completion; preview has 100ms frame support, finite FIR plus declared centered smoothing lookahead and delivery batching; maximum reported algorithmic delay is recorded; no physical capture latency claim",
                            "latency": "full six-second operation distributions include rolling queries; throughput-normalized per-frame cost is an amortized statistic, not worst-case frame delivery latency",
                            "allocationClaim": "All prepared PCM-to-CPPS plus rolling Run cases require zero heap maxima; only OwnedDiagnostics Run may allocate; positive allocation/ARC control required"})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "CPPSBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "CPPSWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "CPPSWorkloadCheck"), "--shard", args.shard))
            validate_matrix(matrix, args.shard)
            names = "|".join(re.escape(row["name"]) for row in matrix)
            plugin += ["--filter", rf"^(CPPS\.(Prepare|Run)\.({names})|{re.escape(CONTROL)})$"]
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
            result["binary"] = smoke.inspect_binary(binary_dir / "CPPSBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "steadyStateAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus zero-heap prepared CPPS/rolling, with owned export allocations reported separately" if args.mode == "allocation" else "instrumentation disabled"})
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
