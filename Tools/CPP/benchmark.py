#!/usr/bin/env python3
"""Measure the A06 CPP matrix with fresh distributions and verified allocation controls."""
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
PACKAGE = ROOT / "Benchmarks"
OPERATIONS = ("Prepare", "Run")
CONTROL = "Capability.CPPAllocationARC"
ALLOCATIONS = ("mallocCountTotal", "mallocBytesCount", "objectAllocCount")
DIAGNOSTICS = (*ALLOCATIONS, "freeCountTotal", "retainCount", "releaseCount")


SHARDS = ('kernels', 'float32-16000', 'float32-48000', 'float64-16000', 'float64-48000')
METHODS = ('leastSquares', 'praat7002Robust', 'siegelRepeatedMedian', 'completeTheilSen')


def expected_cases(shard=None):
    result = {}
    for rate, bins in ((5000, 257), (10000, 513), (20000, 1025)):
        for dense in (False, True):
            for method in METHODS:
                for interpolation in ('none', 'parabolic'):
                    name = f"FitSearch.{bins}bins.{'Dense' if dense else 'Sparse'}.{method}.{interpolation}"
                    result[name] = 'FitSearch', 'float64', rate, bins, 2, dense, method, interpolation
    for precision in ('float32', 'float64'):
        for rate, count in ((10000, 1000), (48000, 48000)):
            name = f'InputConversionChecksum.{precision}.{rate}Hz.{count}samples.2ms'
            result[name] = 'InputConversionChecksum', precision, rate, count, 2, False, 'praat7002Robust', 'parabolic'
        for rate in (16000, 48000):
            for duration in (1, 60):
                for hop in (2, 5, 10):
                    kind = 'IntervalCPP' if hop == 2 else 'PreviewCPP'
                    name = f'{kind}.{precision}.{rate}Hz.{rate * duration}samples.{hop}ms'
                    result[name] = kind, precision, rate, rate * duration, hop, False, 'praat7002Robust', 'parabolic'
    result['OwnedDiagnostics.513bins.Sparse.praat7002Robust.parabolic'] = (
        'OwnedDiagnostics', 'float64', 10000, 513, 2, False, 'praat7002Robust', 'parabolic')
    if shard is not None:
        if shard not in SHARDS:
            raise ValueError('Unknown CPP shard')
        result = {name: row for name, row in result.items()
                  if (f'{row[1]}-{row[2]}' if row[0] in ('IntervalCPP', 'PreviewCPP') else 'kernels') == shard}
    return result


def is_digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def validate_matrix(matrix, shard=None):
    expected = expected_cases(shard)
    seen, input_hashes = set(), {}
    for record in matrix:
        name = record['name']
        if name not in expected or name in seen:
            raise ValueError('Missing, extra, or duplicate CPP case')
        seen.add(name)
        kind, precision, rate, count, hop, dense, method, interpolation = expected[name]
        isolated = kind in ('FitSearch', 'OwnedDiagnostics')
        conversion = kind == 'InputConversionChecksum'
        preview = kind == 'PreviewCPP'
        analysis_rate = rate if isolated else 10000
        bins = count if isolated else 513
        n = bins - 1
        item = record['workload']; config = item['configuration']; profile = item['profile']
        if (item['name'], item['kind'], item['inputSampleCount'], item['inputChunkSamples'], item['densePeaks']) != (name, kind, count, 256, dense):
            raise ValueError('Unexpected workload geometry')
        frame = {'schemaVersion': 1, 'definition': 'praat-7.0.02-power-cepstrum',
                 'sampleRate': analysis_rate, 'precision': 'float64', 'pitchFloorHz': 60,
                 'frameLength': analysis_rate // 10, 'transformLength': 2 * n}
        phases = analysis_rate // math.gcd(rate, analysis_rate)
        conditioning = {'schemaVersion': 1, 'sourceSampleRate': rate, 'targetSampleRate': analysis_rate,
            'precision': 'float64', 'ratio': {'numerator': phases, 'denominator': rate // math.gcd(rate, analysis_rate)},
            'method': {'kind': 'streamingPreview', 'lobes': 16, 'cutoffFraction': 0.9} if preview else
                      {'kind': 'praat7WholeInterval', 'interpolationDepth': 50},
            'preEmphasisFromHz': None, 'declaredInputBandwidthHz': rate / 2,
            'requiredInputBandwidthHz': analysis_rate / 2, 'gainPolicy': 'none'}
        wanted_config = {'schemaVersion': 1, 'inputPrecision': precision, 'frame': frame,
            'conditioning': conditioning, 'hopSeconds': hop / 1000, 'preEmphasisFromHz': 50,
            'previewHopLength': hop * 10 if preview else None}
        settings = {'schemaVersion': 1, 'pitchFloorHz': 60, 'pitchCeilingHz': 330,
                    'interpolation': interpolation, 'fitStartSeconds': .001, 'fitEndSeconds': 0, 'fitMethod': method}
        if config != wanted_config or profile != {'schemaVersion': 1, 'frame': frame,
            'cepstrogram': None if isolated else config, 'settings': settings}:
            raise ValueError('Incorrect numerical recipe, precision, or profile binding')
        identity = item['profileIdentity']
        family = {'completeTheilSen': 'complete-theil-sen-cpp-praat7-peak',
                  'siegelRepeatedMedian': 'siegel-repeated-median-cpp-praat7-peak'}.get(method, 'praat-7.0.02-straight-cpp')
        if identity['identifier'] != {'name': family, 'version': 1} or not is_digest(identity['sha256']):
            raise ValueError('Missing/incorrect profile identity')
        if record['inputDurationSeconds'] != (0 if isolated else count / rate) or record['preparedInputBytes'] != count * (4 if precision == 'float32' else 8):
            raise ValueError('Incorrect input duration or memory')
        digest = record['inputSHA256']
        if not is_digest(digest):
            raise ValueError('Missing input identity')
        input_key = ('power', rate, dense) if isolated else ('pcm', precision, rate, count)
        if input_key in input_hashes and input_hashes[input_key] != digest:
            raise ValueError('Identical prepared signal geometry has inconsistent input hashes')
        input_hashes[input_key] = digest
        slopes = {'leastSquares': 0, 'completeTheilSen': n * (n - 1) // 2,
                  'siegelRepeatedMedian': n * (n - 1), 'praat7002Robust': (n - 1) ** 2}[method]
        scratch = slopes if method == 'completeTheilSen' else n
        cpp_bytes = 8 * (3 * bins + n + scratch + (n if method in ('siegelRepeatedMedian', 'praat7002Robust') else 0))
        if conversion:
            frames, tail, cpp_bytes, n, slopes = 0, 0, 0, 0, 0
            memory = count * 8 if precision == 'float32' else 0
        elif isolated:
            frames, tail, memory = 1, 0, cpp_bytes
        else:
            outputs = count * 10000 // rate
            widening = 32768 if precision == 'float32' else 0
            kernel_bytes = 73600
            if preview:
                frames, tail = (outputs - 1000) // (hop * 10) + 1, 1
                width = 2 * math.ceil(16 / (10000 / rate)) + 1
                upstream_bytes = (phases * width + 2 * width + 256 + 3000 + 256) * 8 + kernel_bytes + widening
            else:
                frames, tail = math.floor((outputs * .0001 - .1) / (hop / 1000)) + 1, 0
                fft = 1 << (count + 1999).bit_length()
                upstream_bytes = (count + outputs + 4 * fft + 2 + 100 * phases + 100 + 1000) * 8 + kernel_bytes + widening
            memory = cpp_bytes + upstream_bytes
        observed = (record['emittedFrameCount'], record['availableFrameCount'], record['unavailableFrameCount'], record['exportedScalarCount'])
        if observed != (frames + tail, frames, tail, 3 * bins if kind == 'OwnedDiagnostics' else 0):
            raise ValueError('Incorrect frame/output coverage')
        for key, value in [('preparedBufferBytes', memory), ('cppBufferBytes', cpp_bytes),
                           ('fitPointCount', n), ('slopeEvaluationCount', slopes)]:
            if type(record[key]) is not int or record[key] != value:
                raise ValueError('Incorrect prepared workspace or bounded fit work')
        if type(record['checksum']) not in (int, float) or not math.isfinite(record['checksum']) or record['checksum'] == 0:
            raise ValueError('Missing finite observable output checksum')
    if seen != set(expected):
        raise ValueError('Missing CPP matrix coverage')
    return matrix


def validate_raw(raw, matrix, mode):
    expected = {f"CPP.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    if mode == "allocation":
        expected.add(CONTROL)
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra raw benchmark distributions")
    allocating_runs = {f"CPP.Run.{r['name']}" for r in matrix
                       if r['workload']['kind'] == 'OwnedDiagnostics'}
    result = {}
    required = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "CPPBenchmarks":
            raise ValueError("Unexpected/duplicate cpp workload")
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
                if name.startswith("CPP.Run.") and name not in allocating_runs and metric in ALLOCATIONS and maximum != 0:
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
    output = PACKAGE / ".build/artifacts" / f"cpp-{args.mode}-{args.shard}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "shard": args.shard, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"cpp-{args.mode}-{args.shard}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/CPPBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "A06 isolated CPP fit/search, actual PCM-to-CPP, conversion, and owned diagnostics; physical evidence deferred under #74",
                            "mode": args.mode, "shard": args.shard, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, one declared Prepare or Run operation",
                            "sampling": "60s Run: one warmup, ten measured operations, 3600s cap. All others: three warmups, thirty measured operations, 60s cap. Validation requires at least ten samples; p99 of ten samples is effectively the maximum, not a stable population tail estimate.",
                            "distributions": "raw-baseline.json.gz; sample counts and maxima in distributions.json; p99.json",
                            "input": "PCM uses original 125/250Hz harmonics plus UInt32 LCG seed33 noise, rounded once to source precision. Isolated power uses a sloped dB background with a Gaussian peak, optionally dense sinusoidal peaks. All generated outside measurement; exact bytes hashed.",
                            "operations": {"Prepare": "construct and destroy declared CPP/FFT/conditioning/conversion workspaces and identities; input generation excluded",
                                           "Run": "one isolated fit/search, full-output conversion checksum, actual 1s/60s PCM-to-CPP, or opt-in owned diagnostics; all CPP scalar diagnostics consumed; reset/finalize included"},
                            "workingMemory": "workloads.json reports CPP and upstream owned scalar buffers including pairwise slopes, FFT scratch and Float widening; opaque FFT tables/object overhead excluded; prepared input separate",
                            "delay": "reference whole-input analysis waits until interval completion; preview has 100ms frame support, finite FIR lookahead and delivery batching; no physical capture latency claim",
                            "latency": "full declared operation distributions; not per-window or end-to-end capture latency unless the operation is an isolated frame",
                            "allocationClaim": "All prepared fit/search, PCM-to-CPP, and conversion Run cases require zero heap maxima; only OwnedDiagnostics Run may allocate; positive allocation/ARC control required"})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "CPPBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "CPPWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "CPPWorkloadCheck"), "--shard", args.shard))
            validate_matrix(matrix, args.shard)
            names = "|".join(re.escape(row["name"]) for row in matrix)
            plugin += ["--filter", rf"^(CPP\.(Prepare|Run)\.({names})|{re.escape(CONTROL)})$"]
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
            result["binary"] = smoke.inspect_binary(binary_dir / "CPPBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "steadyStateAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus zero-heap prepared CPP/conversion, with owned export allocations reported separately" if args.mode == "allocation" else "instrumentation disabled"})
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
