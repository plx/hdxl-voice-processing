#!/usr/bin/env python3
"""Measure the A03 conditioning matrix with fresh distributions and verified allocation controls."""
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
OPERATIONS = ("Prepare", "Condition", "ConditionFFT")
CONTROL = "Capability.ConditioningAllocationARC"
ALLOCATIONS = ("mallocCountTotal", "mallocBytesCount", "objectAllocCount")
DIAGNOSTICS = (*ALLOCATIONS, "freeCountTotal", "retainCount", "releaseCount")


def validate_matrix(matrix):
    expected = {(precision, profile, source, target, duration, chunk)
                for precision in ("float32", "float64") for profile in ("Praat7", "Preview")
                for source in (16000, 44100, 48000)
                for target, duration, chunk in ([(t, 1, c) for t in (10000, 11000, 16000) for c in (64, 256, 1024)] + [(10000, 60, 1024)])}
    seen, checksums = set(), {}
    for record in matrix:
        item = record["workload"]
        config = item["configuration"]
        profile = "Preview" if config["method"]["kind"] == "streamingPreview" else "Praat7"
        source, target = config["sourceSampleRate"], config["targetSampleRate"]
        duration, chunk = item["inputDurationSeconds"], item["inputChunkSamples"]
        key = (config["precision"], profile, source, target, duration, chunk)
        name = f"{profile}.{key[0]}.{source}-{target}Hz.{duration}s.C{chunk}"
        if key not in expected or key in seen or record["name"] != name or item["name"] != name:
            raise ValueError("Missing, extra, or duplicate conditioning matrix case")
        seen.add(key)
        expected_method = {"kind":"streamingPreview", "lobes":32, "cutoffFraction":0.9} if profile == "Preview" else {"kind":"praat7WholeInterval", "interpolationDepth":50}
        if config["method"] != expected_method or config["preEmphasisFromHz"] != 50 or config["gainPolicy"] != "none":
            raise ValueError("Unexpected conditioning numerical profile")
        if (item["frameSamples"], item["hopSamples"], item["fftLength"], item["outputBlockCapacity"], item["intervalsPerIteration"]) != (1024, 256, 1024, 256, 1):
            raise ValueError("Unexpected conditioning pipeline geometry")
        count = duration * target
        if record["outputSampleCount"] != count or record["pipelineFrameCount"] != (count - 1024) // 256 + 1:
            raise ValueError("Invalid conditioning count or FFT frame coverage")
        width = 4 if key[0] == "float32" else 8
        if record["preparedInputBytes"] != duration * source * width:
            raise ValueError("Unexpected prepared input memory")
        memory = record["conditionerScalarWorkspaceBytes"]
        if type(memory) is not int or memory <= 0 or type(record["pipelineScalarWorkspaceBytes"]) is not int or record["pipelineScalarWorkspaceBytes"] <= memory:
            raise ValueError("Invalid scalar workspace evidence")
        delay = duration / 2 if profile == "Praat7" else (math.ceil(32 / min(1, target / source)) + 0.5) / source
        if not math.isfinite(record["filterDelaySeconds"]) or abs(record["filterDelaySeconds"] - delay) > 1e-14:
            raise ValueError("Invalid recorded filter delay")
        values = (record["outputEnergy"], record["pipelineSpectralEnergy"])
        if any(isinstance(x, bool) or not isinstance(x, (int, float)) or not math.isfinite(x) or x <= 0 for x in values):
            raise ValueError("Invalid observable conditioning checksum")
        group = key[:-1]
        if group in checksums and checksums[group] != values:
            raise ValueError("Conditioning benchmark changes output with chunk partition")
        checksums[group] = values
    if seen != expected:
        raise ValueError("Missing conditioning matrix coverage")
    return matrix


def validate_raw(raw, matrix, mode):
    expected = {f"Conditioning.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    if mode == "allocation":
        expected.add(CONTROL)
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra raw benchmark distributions")
    result = {}
    required = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "ConditioningBenchmarks":
            raise ValueError("Unexpected/duplicate conditioning workload")
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
                if name.startswith("Conditioning.") and not name.startswith("Conditioning.Prepare.") and metric in ALLOCATIONS and maximum != 0:
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
    output = PACKAGE / ".build/artifacts" / f"conditioning-{args.mode}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"conditioning-{args.mode}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/ConditioningBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "A03 conditioning host matrix; physical evidence deferred under #74",
                            "mode": args.mode, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, one complete source interval",
                            "distributions": "raw-baseline.json.gz; sample counts and maxima in distributions.json; p99.json",
                            "input": "Original UInt32 LCG seed31; (state-2^31)/2^32, rounded to input precision; prepared before measurement",
                            "operations": {"Prepare": "one conditioner including setup, coefficient cache, workspace, identity, and destruction; downstream FFT/framer setup excluded",
                                           "Condition": "reset and consume one interval in declared chunks, finish, sum squared output as observable checksum",
                                           "ConditionFFT": "reset and consume one interval through conditioning, rectangular 1024-sample frames/hop256, 1024-point real FFT, one-sided Parseval energy checksum"},
                            "workingMemory": "workloads.json scalar workspace excludes opaque Accelerate setup/object/allocator overhead; includes mirrored preview history; pipeline adds FFT, bins, and framer/window storage; prepared input reported separately",
                            "delay": "whole input duration/2 or preview maximum FIR lookahead; per-block input-clock delivery delay serialized by API; excludes host scheduling/compute time",
                            "allocationClaim": "Prepared Condition and ConditionFFT, including reset/finalize; setup excluded; all counters need positive control"})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "ConditioningBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "ConditioningWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "ConditioningWorkloadCheck")))
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
            result["binary"] = smoke.inspect_binary(binary_dir / "ConditioningBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "steadyStateAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus both prepared operations for all configurations" if args.mode == "allocation" else "instrumentation disabled"})
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
