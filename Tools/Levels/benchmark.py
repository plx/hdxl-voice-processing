#!/usr/bin/env python3
"""Measure the A04 level matrix with fresh distributions and verified allocation controls."""
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
OPERATIONS = ("Prepare", "Analyze")
CONTROL = "Capability.LevelAllocationARC"
ALLOCATIONS = ("mallocCountTotal", "mallocBytesCount", "objectAllocCount")
DIAGNOSTICS = (*ALLOCATIONS, "freeCountTotal", "retainCount", "releaseCount")


def expected_cases():
    result = {}
    for precision in ("float32", "float64"):
        for method in ("direct", "compensatedSliding"):
            geometries = [([(r, ms)], weighted, "noise") for r in (16000, 44100, 48000)
                          for ms in (10, 50, 400) for weighted in (False, True)]
            geometries += [([(r, 400)], True, signal) for r in (16000, 44100, 48000)
                           for signal in ("silence", "denormal")]
            geometries += [([(16000, 10), (44100, 50), (48000, 400)], True, "noise")]
            for geometry, weighted, signal in geometries:
                suffix = "+".join(f"{r}Hz-{ms}ms" for r, ms in geometry)
                name = f"{precision}.{method}.{'K' if weighted else 'Raw'}.{signal}.{suffix}"
                result[name] = (precision, method, weighted, signal, geometry)
    return result


def validate_matrix(matrix):
    expected = expected_cases()
    seen = set()
    for record in matrix:
        name = record["name"]
        if name not in expected or name in seen:
            raise ValueError("Missing, extra, or duplicate level matrix case")
        seen.add(name)
        precision, method, weighted, signal, geometry = expected[name]
        item = record["workload"]
        if (item["name"], item["signal"], item["inputDurationSeconds"], item["inputChunkSamples"], item["instances"]) != (name, signal, 1, 256, len(geometry)):
            raise ValueError("Unexpected level input or instance geometry")
        if len(item["configurations"]) != len(geometry) or len(item["profileIdentities"]) != len(geometry):
            raise ValueError("Missing per-instance profiles")
        frames = warmup = workspace = input_bytes = 0
        for config, identity, (rate, ms) in zip(item["configurations"], item["profileIdentities"], geometry):
            window, hop = rate * ms // 1000, rate // 100
            weighting = {"kind": "bs1770Revision5", "warmupSampleCount": rate // 10} if weighted else {"kind": "none"}
            if (config["sampleRate"], config["windowLength"], config["hopLength"], config["inputPrecision"],
                config["arithmeticPrecision"], config["accumulation"], config["weighting"], config["partialWindowPolicy"]) != (rate, window, hop, precision, "float64", method, weighting, "discard"):
                raise ValueError("Unexpected numerical level profile")
            if (config["pcmReference"], config["channelPolicy"], config["averaging"], config["energyUnit"], config["logLevelUnit"]) != ("unitPeak", "monoAlreadySelected", "rectangularMeanSquare", "normalizedSquaredAmplitude", "decibelsFullScale"):
                raise ValueError("Unexpected level reference or units")
            if identity["identifier"] != {"name": "digital-level-windows", "version": 1} or len(identity["sha256"]) != 64 or any(c not in "0123456789abcdef" for c in identity["sha256"]):
                raise ValueError("Invalid recorded profile identity")
            if weighted:
                coefficients = config["kWeighting"]
                if coefficients["sampleRate"] != rate or coefficients["method"] != {"name": "bs1770-5-prewarped-tables", "version": 1}:
                    raise ValueError("Invalid K coefficient provenance")
            elif config["kWeighting"] is not None:
                raise ValueError("Unexpected K weighting")
            n = (rate - window) // hop + 1
            frames += n
            warmup += min(n, 10) if weighted else 0
            workspace += window * (56 if weighted else 32)
            input_bytes += rate * (4 if precision == "float32" else 8)
        eligible = frames - warmup if weighted else 0
        limited = eligible if precision == "float64" and signal == "denormal" else 0
        counts = (record["frameCount"], record["warmupWindowCount"], record["weightedAvailableWindowCount"], record["weightedRangeLimitedWindowCount"], record["subnormalInputWindowCount"])
        if counts != (frames, warmup, eligible - limited, limited, frames if signal == "denormal" else 0):
            raise ValueError("Incorrect level window availability or warm-up coverage")
        if record["preparedBufferBytes"] != workspace or record["preparedInputBytes"] != input_bytes:
            raise ValueError("Incorrect level prepared memory")
        checksum = record["checksum"]
        if isinstance(checksum, bool) or not isinstance(checksum, (int, float)) or not math.isfinite(checksum) or (checksum != 0 if signal == "silence" else checksum <= 0):
            raise ValueError("Invalid observable level checksum")
    if seen != set(expected):
        raise ValueError("Missing level matrix coverage")
    return matrix


def validate_raw(raw, matrix, mode):
    expected = {f"Level.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
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
        if name not in expected or name in result or identity["target"] != "LevelBenchmarks":
            raise ValueError("Unexpected/duplicate level workload")
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
                if name.startswith("Level.") and not name.startswith("Level.Prepare.") and metric in ALLOCATIONS and maximum != 0:
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
    output = PACKAGE / ".build/artifacts" / f"level-{args.mode}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"level-{args.mode}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/LevelBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "A04 level host matrix; physical evidence deferred under #74",
                            "mode": args.mode, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, one declared Prepare or Analyze batch",
                            "distributions": "raw-baseline.json.gz; sample counts and maxima in distributions.json; p99.json",
                            "input": "Original UInt32 LCG seed32 noise; silence; or input-precision denormals leastNormal/64*(state%31-15); prepared before measurement",
                            "operations": {"Prepare": "construct and destroy the declared independently configured analyzers, including coefficients, buffers and profile identities",
                                           "Analyze": "reset, consume one second per analyzer in 256-sample chunks, discard incomplete final grid, accumulate normalized energy checksum; includes explicit 100ms K-filter warm-up"},
                            "workingMemory": "workloads.json reports owned raw/weighted rings and monotonic peak queues; excludes object/allocator/scalar overhead; prepared input separate",
                            "delay": "per-profile rectangular window duration/2; causal K phase/group delay is frequency-dependent and separately inspectable; no timestamp shift",
                            "latency": "raw distributions measure a complete reset-and-analyze batch, not individual window or end-to-end capture latency; divide total input seconds by batch seconds for throughput",
                            "allocationClaim": "Prepared Analyze including ordinary reset and finish; setup excluded; all counters need positive control"})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "LevelBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "LevelWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "LevelWorkloadCheck")))
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
            result["binary"] = smoke.inspect_binary(binary_dir / "LevelBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "steadyStateAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus prepared Analyze for all configurations" if args.mode == "allocation" else "instrumentation disabled"})
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
