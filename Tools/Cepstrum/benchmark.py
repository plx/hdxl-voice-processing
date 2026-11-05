#!/usr/bin/env python3
"""Measure the A05 cepstrum matrix with fresh distributions and verified allocation controls."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import math
import os
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
CONTROL = "Capability.CepstrumAllocationARC"
ALLOCATIONS = ("mallocCountTotal", "mallocBytesCount", "objectAllocCount")
DIAGNOSTICS = (*ALLOCATIONS, "freeCountTotal", "retainCount", "releaseCount")


def expected_cases():
    result = {}
    def add(kind, precision, rate, count, hop=2, preview=False):
        name = f"{kind}.{precision}.{rate}Hz.{count}samples.{'Preview' if preview else 'Reference'}.{hop}ms"
        result[name] = kind, precision, rate, count, hop, preview
    for precision in ('float32', 'float64'):
        add('FrameChecksum', precision, 10000, 1000)
        add('FrameStageExport', precision, 10000, 1000)
        for rate, count in ((10000, 1000), (48000, 48000)):
            add('InputConversionChecksum', precision, rate, count)
        for rate in (16000, 48000):
            for duration in (1, 60):
                for hop in (2, 5, 10):
                    add('IntervalChecksum' if hop == 2 else 'PreviewChecksum', precision,
                        rate, rate * duration, hop, hop != 2)
        for hop in (2, 5, 10):
            add('BoundedMatrixExport', precision, 48000, 48000, hop, hop != 2)
    return result


def is_digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def validate_matrix(matrix):
    expected = expected_cases()
    seen, input_hashes = set(), {}
    for record in matrix:
        name = record['name']
        if name not in expected or name in seen:
            raise ValueError('Missing, extra, or duplicate cepstrum case')
        seen.add(name)
        kind, precision, rate, count, hop, preview = expected[name]
        item = record['workload']; config = item['configuration']
        f = config['frame']; c = config['conditioning']
        frame_only = kind in ('FrameChecksum', 'FrameStageExport')
        conversion = kind == 'InputConversionChecksum'
        matrix_export = kind == 'BoundedMatrixExport'
        if (item['name'], item['kind'], item['inputSampleCount'], item['inputChunkSamples'],
            item['matrixMaximumFrames'], item['matrixMaximumScalars']) != (name, kind, count, 256, 500 if matrix_export else 0, 256500 if matrix_export else 0):
            raise ValueError('Unexpected workload geometry or retention budget')
        if f != {'schemaVersion': 1, 'definition': 'praat-7.0.02-power-cepstrum', 'sampleRate': 10000,
                 'precision': 'float64', 'pitchFloorHz': 60, 'frameLength': 1000, 'transformLength': 1024}:
            raise ValueError('Unexpected cepstral numerical definition or arithmetic precision')
        method = {'kind':'streamingPreview', 'lobes':16, 'cutoffFraction':0.9} if preview else {'kind':'praat7WholeInterval', 'interpolationDepth':50}
        divisor = math.gcd(rate, 10000); phases = 10000 // divisor
        if c != {'schemaVersion':1, 'sourceSampleRate':rate, 'targetSampleRate':10000,
            'precision':'float64', 'ratio':{'numerator':phases, 'denominator':rate // divisor},
            'method':method, 'preEmphasisFromHz':None, 'declaredInputBandwidthHz':rate / 2,
            'requiredInputBandwidthHz':5000, 'gainPolicy':'none'}:
            raise ValueError('Unexpected conditioning definition')
        if (config['schemaVersion'], config['inputPrecision'], config['hopSeconds'], config['preEmphasisFromHz'], config['previewHopLength']) != (1, precision, hop / 1000, 50, hop * 10 if preview else None):
            raise ValueError('Unexpected source precision, grid or fused pre-emphasis')
        identities = item['profileIdentities']
        identity_name = ('praat-7.0.02-power-cepstrum' if frame_only else
                         'finite-fir-preview-cepstrogram' if preview else 'praat-7.0.02-cepstrogram')
        if len(identities) != (0 if conversion else 1) or any(
            p['identifier'] != {'name': identity_name, 'version': 1} or not is_digest(p['sha256']) for p in identities):
            raise ValueError('Missing/incorrect profile identity')
        if record['inputDurationSeconds'] != count / rate or record['preparedInputBytes'] != count * (4 if precision == 'float32' else 8):
            raise ValueError('Incorrect input duration or memory')
        if not is_digest(record['inputSHA256']):
            raise ValueError('Missing source PCM identity')
        input_key = precision, rate, count
        if input_key in input_hashes and input_hashes[input_key] != record['inputSHA256']:
            raise ValueError('Identical prepared signal geometry has inconsistent PCM hashes')
        input_hashes[input_key] = record['inputSHA256']
        kernel_bytes = (1024 + 8 * 513 + 1024 + 1000 + 2 * 1024) * 8
        if conversion:
            frames, tail = 0, 0
            memory = count * 8 if precision == 'float32' else 0
        elif frame_only:
            frames, tail = 1, 0
            memory = kernel_bytes + (count * 8 if precision == 'float32' else 0)
        else:
            outputs = count * 10000 // rate
            widening = 4096 * 8 if precision == 'float32' else 0
            if preview:
                frames, tail = (outputs - 1000) // (hop * 10) + 1, 1
                radius = math.ceil(16 / (10000 / rate)); width = 2 * radius + 1
                conditioning_bytes = (phases * width + 2 * width + 256) * 8
                memory = conditioning_bytes + kernel_bytes + (3 * 1000 + 256) * 8 + widening
            else:
                frames, tail = math.floor((outputs * 0.0001 - 0.1) / (hop / 1000)) + 1, 0
                fft = 1 << (count + 2000 - 1).bit_length()
                conditioning_bytes = (count + outputs + 4 * fft + 2 + 100 * phases + 100) * 8
                memory = conditioning_bytes + kernel_bytes + 1000 * 8 + widening
        exported = 4102 if kind == 'FrameStageExport' else frames * 513 if matrix_export else 0
        observed = (record['emittedFrameCount'], record['completeFrameCount'], record['unavailableFrameCount'], record['retainedFrameCount'], record['exportedScalarCount'])
        if observed != (frames + tail, frames, tail, frames + tail if matrix_export else 0, exported):
            raise ValueError('Incorrect emitted/available/retained frame or scalar coverage')
        if type(record['preparedBufferBytes']) is not int or record['preparedBufferBytes'] != memory:
            raise ValueError('Incorrect prepared workspace evidence')
        value = record['checksum']
        if type(value) not in (int, float) or not math.isfinite(value) or value == 0:
            raise ValueError('Missing finite observable output checksum')
    if seen != set(expected):
        raise ValueError('Missing cepstrum matrix coverage')
    return matrix


def validate_raw(raw, matrix, mode):
    expected = {f"Cepstrum.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    if mode == "allocation":
        expected.add(CONTROL)
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra raw benchmark distributions")
    allocating_runs = {f"Cepstrum.Run.{r['name']}" for r in matrix
                       if r['workload']['kind'] in ('FrameStageExport', 'BoundedMatrixExport')}
    result = {}
    required = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "CepstrumBenchmarks":
            raise ValueError("Unexpected/duplicate cepstrum workload")
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
                if name.startswith("Cepstrum.Run.") and name not in allocating_runs and metric in ALLOCATIONS and maximum != 0:
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
    args = parser.parse_args()
    output = PACKAGE / ".build/artifacts" / f"cepstrum-{args.mode}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"cepstrum-{args.mode}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/CepstrumBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "A05 pre-CPP checksum baseline, conversion, and opt-in export; actual CPP consumption belongs to #35; physical evidence deferred under #74",
                            "mode": args.mode, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, one declared Prepare or Run operation",
                            "distributions": "raw-baseline.json.gz; sample counts and maxima in distributions.json; p99.json",
                            "input": "Original 125/250Hz harmonic signal plus UInt32 LCG seed33 noise, rounded once to source precision; prepared outside measurement. Isolated frame cases treat this as already-conditioned input.",
                            "operations": {"Prepare": "construct and destroy declared FFT/conditioning/frame/conversion workspaces and identities; input generation excluded",
                                           "Run": "declared single frame, full-output conversion checksum, 1s/60s pipeline checksum, or opt-in owned stage/matrix export; reset/finalize included"},
                            "workingMemory": "workloads.json reports owned scalar buffers including windows, FFT scratch and Float widening; opaque FFT tables and object overhead excluded; prepared source PCM separate",
                            "delay": "reference whole-input analysis waits until interval completion; preview has 100ms frame support, finite FIR lookahead and delivery batching; no physical capture latency claim",
                            "latency": "full declared operation distributions; not per-window or end-to-end capture latency unless the operation is an isolated frame",
                            "allocationClaim": "All prepared checksum/conversion Run cases require zero heap maxima; explicit owned stage/matrix exports may allocate and are reported separately; positive allocation/ARC control required"})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "CepstrumBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "CepstrumWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "CepstrumWorkloadCheck")))
            validate_matrix(matrix)
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
            result["binary"] = smoke.inspect_binary(binary_dir / "CepstrumBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "steadyStateAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus zero-heap prepared checksums/conversion, with owned export allocations reported separately" if args.mode == "allocation" else "instrumentation disabled"})
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
