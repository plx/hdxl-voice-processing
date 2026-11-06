#!/usr/bin/env python3
"""Measure bounded capture offers; verify fresh distributions and allocator controls."""
import argparse
import gzip
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
CONTROL = "Capability.TransportAllocationARC"
HEAP = ("mallocCountTotal", "mallocBytesCount", "objectAllocCount", "freeCountTotal")
DIAGNOSTICS = (*HEAP, "retainCount", "releaseCount")


def validate_workloads(matrix):
    operations = {"FirstOffer", "AcceptedBurst", "Overflow", "Oversized", "Invalid", "Closed", "GapRecovery"}
    if not isinstance(matrix, list) or len(matrix) != 70 or len({row["name"] for row in matrix}) != 70:
        raise ValueError("Expected 70 unique transport workloads")
    configurations = {}
    for row in matrix:
        config = row["configuration"]
        key = (config["encoding"], config["layout"], config["channels"], config["frames"], config["slots"])
        configurations.setdefault(key, set()).add(row["operation"])
        expected_name = (f"Transport.{row['operation']}.{key[0]}-{key[1]}-c{key[2]}-n{key[3]}-s{key[4]}")
        if row["name"] != expected_name or row["verified"]["operationsPerIteration"] <= 0:
            raise ValueError("Invalid workload identity or operation count")
    if len(configurations) != 10 or any(value != operations for value in configurations.values()):
        raise ValueError("Incomplete transport operation/configuration matrix")
    if {key[:2] for key in configurations} != {
        (encoding, layout) for encoding in ("float32", "float64") for layout in ("interleaved", "planar")
    } or max(key[2] for key in configurations) != 32 or max(key[3] for key in configurations) != 65536:
        raise ValueError("Missing precision/layout/channel/maximum-frame coverage")
    return {row["name"] for row in matrix}


def validate_raw(raw, names, mode):
    expected = set(names) | ({CONTROL} if mode == "allocation" else set())
    rows = raw["results"]
    if not isinstance(rows, list) or len(rows) != 2 * len(expected):
        raise ValueError("Missing/extra transport benchmark distributions")
    required = {"wallClock", "cpuTotal"} if mode == "timing" else {"wallClock", *DIAGNOSTICS}
    result = {}
    for index in range(0, len(rows), 2):
        identity, measurements = rows[index:index + 2]
        name = identity["name"]
        if name not in expected or name in result or identity["target"] != "TransportBenchmarks":
            raise ValueError("Invalid/duplicate benchmark identity")
        metrics = {}
        for measurement in measurements:
            if len(measurement["metric"]) != 1 or measurement["scalingFactor"] != 1:
                raise ValueError("Unexpected metric identity/scaling")
            metric = next(iter(measurement["metric"]))
            histogram = measurement["statistics"]["histogram"]
            count, maximum = histogram["_totalCount"], histogram["maxValue"]
            if metric not in required or metric in metrics or type(count) is not int or count < 10:
                raise ValueError("Missing metric or fewer than ten measured samples")
            if type(maximum) is not int or maximum < 0 or sum(histogram["counts"]) != count:
                raise ValueError("Malformed histogram evidence")
            if metric == "wallClock" and maximum <= 0:
                raise ValueError("No positive measured duration")
            if mode == "allocation":
                if name == CONTROL and metric in DIAGNOSTICS and maximum <= 0:
                    raise ValueError(f"Allocation/ARC capability unavailable: {metric}")
                if name != CONTROL and metric in HEAP and maximum != 0:
                    raise ValueError(f"Capture-path heap activity: {name}, {metric}, max={maximum}")
            metrics[metric] = {"sampleCount": count, "maximum": maximum}
        if set(metrics) != required:
            raise ValueError("Incomplete metric coverage")
        result[name] = metrics
    return result


def validate_export(rows, names, mode):
    metrics = ("Time (wall clock)", "Time (total CPU)") if mode == "timing" else (
        "Time (wall clock)", *smoke.DIAGNOSTICS)
    expected = {f"{name} - {metric}" for name in names for metric in metrics}
    found = set()
    if not isinstance(rows, list):
        raise ValueError("Invalid p99 export")
    for row in rows:
        name, value = row["name"], row["value"]
        if name not in expected or name in found or isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("Missing/duplicate/invalid p99 metric")
        if not math.isfinite(value) or value < 0 or row["unit"] != ("ns" if " - Time (" in name else "#"):
            raise ValueError("Nonfinite/negative/untyped p99 value")
        found.add(name)
    if found != expected:
        raise ValueError("Incomplete p99 coverage")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("timing", "allocation"))
    args = parser.parse_args()
    output = PACKAGE / ".build/artifacts" / f"transport-{args.mode}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"transport-{args.mode}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/TransportBenchmarks" / name
    try:
        if any(key in os.environ for key in (
            "MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
            "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
            "DYLD_INSERT_LIBRARIES", "LD_PRELOAD",
        )):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({
            "purpose": "synthetic bounded PCM capture-offer microbenchmarks",
            "measurement": "capture offers only; allocation/preparation, worker drain and verification excluded",
            "firstOffer": "first call per freshly prepared instance; process/runtime already initialized",
            "timingInterpretation": "unscaled batch distributions; batch p99 is not individual callback p99",
            "physicalEvidence": "not collected; #74 and #121",
            "operationCounts": "workloads.json verified.operationsPerIteration",
        })
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "TransportBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "TransportWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "TransportWorkloadCheck")))
            names = validate_workloads(matrix)
            (output / "workloads.json").write_text(json.dumps(matrix, indent=2) + "\n")
            if baseline.exists():
                raise ValueError("Fresh baseline already exists")
            run([*plugin, "baseline", "update", name])
            raw = json.loads((baseline / "results.json").read_text())
            if raw.get("baselineName") != name:
                raise ValueError("Unexpected baseline identity")
            raw["machine"]["hostname"] = "<host>"
            with gzip.open(output / "raw-baseline.json.gz", "wt") as stream:
                json.dump(raw, stream, separators=(",", ":"), allow_nan=False)
            summary = validate_raw(raw, names, args.mode)
            (output / "distributions.json").write_text(json.dumps(summary, indent=2) + "\n")
            result["binary"] = smoke.inspect_binary(binary_dir / "TransportBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exported = output / f"{name}.json"
            validate_export(json.loads(exported.read_text()), summary, args.mode)
            # The framework export is retained alongside raw histograms; histogram
            # maxima, not a rounded p99 export, enforce the no-heap gate above.
            exported.rename(output / "p99.json")
            result.update(status="passed", workloadCount=len(matrix), benchmarkCount=len(summary),
                          heapActivityMaximum=0 if args.mode == "allocation" else None,
                          instrumentation="malloc/ARC positive controls" if args.mode == "allocation" else "disabled")
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
