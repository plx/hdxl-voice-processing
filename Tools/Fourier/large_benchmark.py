#!/usr/bin/env python3
"""Measure the bounded whole-interval Fourier host matrix with fresh distributions and verified allocation controls."""
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
OPERATIONS = ("Prepare", "ForwardReal", "InverseReal", "ForwardComplex", "InverseComplex")
CONTROL = "Capability.LargeFourierAllocationARC"
ALLOCATIONS = ("mallocCountTotal", "mallocBytesCount", "objectAllocCount")
DIAGNOSTICS = (*ALLOCATIONS, "freeCountTotal", "retainCount", "releaseCount")


def validate_raw(raw, matrix, mode):
    expected = {f"LargeFourier.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    if mode == "allocation":
        expected.add(CONTROL)
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra raw benchmark distributions")
    result = {}
    required = {"wallClock", "cpuTotal", "peakMemoryResident"} if mode == "timing" else {"wallClock", "peakMemoryResident", *DIAGNOSTICS}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "LargeFourierBenchmarks":
            raise ValueError("Unexpected/duplicate fourier workload")
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
            if metric == "peakMemoryResident" and name != CONTROL and maximum <= 0:
                raise ValueError("Resident memory metric unavailable for a workload")
            if mode == "allocation":
                if name == CONTROL and metric in DIAGNOSTICS and maximum <= 0:
                    raise ValueError(f"Unavailable allocation/ARC capability: {metric}")
                if name.startswith("LargeFourier.") and not name.startswith("LargeFourier.Prepare.") and metric in ALLOCATIONS and maximum != 0:
                    raise ValueError(f"Steady-state allocation observed: {name}, {metric}, maximum={maximum}")
            metrics[metric] = {"sampleCount": count, "maximum": maximum}
        if set(metrics) != required:
            raise ValueError("Missing metric coverage")
        result[name] = metrics
    return result


def validate_export(rows, names, mode):
    metrics = ("Time (wall clock)", "Time (total CPU)", "Memory (resident peak)") if mode == "timing" else ("Time (wall clock)", "Memory (resident peak)", *smoke.DIAGNOSTICS)
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
    output = PACKAGE / ".build/artifacts" / f"fourier-large-{args.mode}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"fourier-large-{args.mode}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/LargeFourierBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "Whole-interval FFT capacity for #31; host measurement, not physical-device feasibility",
                            "mode": args.mode, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, unscaled outer iteration",
                            "distributions": "raw-baseline.json.gz; sample counts and maxima in distributions.json; p99.json",
                            "input": "Original LCG: UInt32 state=95; state=1664525*state+1013904223 modulo 2^32; (state-2^31)/2^31, rounded to input precision; prepared before measurement",
                            "operations": {"Prepare": "one FFT plan including setup, workspace, identity, and destruction",
                                           "ForwardReal": "one prepared real forward transform",
                                           "InverseReal": "one prepared real inverse transform",
                                           "ForwardComplex": "one prepared complex forward transform",
                                           "InverseComplex": "one prepared complex inverse transform"},
                            "allocationClaim": "Four prepared transform operations only; setup excluded",
                            "memoryMetric": "peakMemoryResident is OS-sampled process resident memory in bytes (backend count unit, factor 1); includes harness/setup/caller buffers, not exclusive workspace bytes or per-call allocation",
                            "memoryCapability": "requires positive resident-memory observations; no device budget asserted"})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "LargeFourierBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "LargeFourierWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "LargeFourierWorkloadCheck")))
            if len(matrix) != 12 or len({item["name"] for item in matrix}) != 12:
                raise ValueError("Large Fourier workload matrix coverage mismatch")
            expected_cases = {(precision, 1 << exponent) for precision in ("float32", "float64") for exponent in range(17, 23)}
            if {(item["configuration"]["precision"], item["configuration"]["length"]) for item in matrix} != expected_cases:
                raise ValueError("Large Fourier size/precision coverage mismatch")
            if any(item["operationsPerIteration"] != 1 or item["configuration"]["sampleRate"] != 48000 for item in matrix):
                raise ValueError("Large Fourier denominator or rate changed")
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
            result["binary"] = smoke.inspect_binary(binary_dir / "LargeFourierBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "residentMemoryMaximumBytes": max(metrics["peakMemoryResident"]["maximum"] for metrics in summary.values()), "steadyStateAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus all four prepared operations at every size and precision" if args.mode == "allocation" else "instrumentation disabled"})
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
