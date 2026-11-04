#!/usr/bin/env python3
"""Measure the A02 host matrix with fresh distributions and verified allocation controls."""
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
OPERATIONS = ("PrepareFFT", "PrepareSpectrum", "ForwardReal", "InverseReal", "ForwardComplex", "InverseComplex", "Spectrum", "Cepstrum")
CONTROL = "Capability.FourierAllocationARC"
ALLOCATIONS = ("mallocCountTotal", "mallocBytesCount", "objectAllocCount")
DIAGNOSTICS = (*ALLOCATIONS, "freeCountTotal", "retainCount", "releaseCount")


def validate_raw(raw, matrix, mode):
    expected = {f"Fourier.{operation}.{item['name']}" for item in matrix for operation in OPERATIONS}
    expected.update(f"Fourier.ScalarDFT.{item['name']}" for item in matrix if item['configuration']['length'] <= 128)
    if mode == "timing":
        expected.update(f"Fourier.{ordering}{operation}.{item['name']}" for item in matrix
                        for ordering in ("Sequential4", "Concurrent4") for operation in ("Spectrum", "Cepstrum"))
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
        if name not in expected or name in result or identity["target"] != "FourierBenchmarks":
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
            if mode == "allocation":
                if name == CONTROL and metric in DIAGNOSTICS and maximum <= 0:
                    raise ValueError(f"Unavailable allocation/ARC capability: {metric}")
                if name.startswith("Fourier.") and not name.startswith(("Fourier.PrepareFFT.", "Fourier.PrepareSpectrum.", "Fourier.ScalarDFT.")) and metric in ALLOCATIONS and maximum != 0:
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
    output = PACKAGE / ".build/artifacts" / f"fourier-{args.mode}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    result = {"schemaVersion": 1, "mode": args.mode, "status": "failed", "commands": []}
    lock = PACKAGE / "Package.resolved"
    before = lock.read_bytes()
    name = f"fourier-{args.mode}-{uuid.uuid4().hex}"
    baseline = PACKAGE / ".benchmarkBaselines/FourierBenchmarks" / name
    try:
        overrides = ("MALLOC_INTERPOSER_LOCAL_PATH", "RUNTIME_INTERPOSER_LOCAL_PATH",
                     "BENCHMARK_DISABLE_MALLOC_INTERPOSER", "BENCHMARK_DISABLE_JEMALLOC",
                     "DYLD_INSERT_LIBRARIES", "LD_PRELOAD")
        if any(key in os.environ for key in overrides):
            raise ValueError("Remove allocator/backend environment overrides")
        environment = ci.environment("release")
        ci.validate_environment(environment, json.loads((ROOT / "Configuration/build.json").read_text()))
        environment.update({"hardwareModel": ci.capture("sysctl", "-n", "hw.model"),
                            "purpose": "A02 host Fourier/spectrum matrix, not physical-device evidence",
                            "mode": args.mode, "packageResolvedSHA256": hashlib.sha256(before).hexdigest(),
                            "frameworkScalingFactor": 1, "exportStatistic": "p99, unscaled outer iteration",
                            "distributions": "raw-baseline.json.gz; sample counts and maxima in distributions.json; p99.json",
                            "input": "Original LCG: UInt32 state=30; state=1664525*state+1013904223 modulo 2^32; (state-2^31)/2^31, rounded to input precision; prepared before measurement",
                            "operations": {"PrepareFFT": "one plan including setup, workspace, identity, and destruction",
                                           "PrepareSpectrum": "one spectrum conversion workspace, gains, identities, and destruction",
                                           "ForwardReal": "10 prepared real forward transforms", "InverseReal": "10 prepared real inverse transforms",
                                           "ForwardComplex": "10 prepared complex forward transforms", "InverseComplex": "10 prepared complex inverse transforms",
                                           "Spectrum": "10 real forward plus window-normalized one-sided power conversions",
                                           "Cepstrum": "10 real forward, caller log power with explicit 1e-30 floor, real inverse",
                                           "ScalarDFT": "10 bounded direct complex DFTs, binary64 accumulation even for Float input",
                                           "Sequential4/Concurrent4": "4 independently prepared actors, 10 spectrum or cepstrum operations each; includes actor/task scheduling; timing only"},
                            "allocationClaim": "Prepared ForwardReal/InverseReal/ForwardComplex/InverseComplex/Spectrum/Cepstrum only; setup, scalar comparison, and task scheduling excluded"})
        (output / "environment.json").write_text(ci.redact(json.dumps(environment, indent=2)) + "\n")
        (output / "resolution.json").write_bytes(before)
        common = smoke.swift_arguments(args.mode)
        plugin = ["swift", "package", *common, "--allow-writing-to-package-directory", "benchmark",
                  "--target", "FourierBenchmarks", "--time-units", "nanoseconds", "--no-progress"]
        with (output / "commands.log").open("w") as log:
            def run(command):
                ci.run_command(command, log, result["commands"])
            run([sys.executable, "Tools/verify-provenance.py"])
            run(["swift", "build", *common, "--product", "FourierWorkloadCheck"])
            binary_dir = Path(ci.capture("swift", "build", *common, "--show-bin-path"))
            matrix = json.loads(ci.capture(str(binary_dir / "FourierWorkloadCheck")))
            if len(matrix) != 22 or len({item["name"] for item in matrix}) != 22:
                raise ValueError("Fourier workload matrix coverage mismatch")
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
            result["binary"] = smoke.inspect_binary(binary_dir / "FourierBenchmarks", args.mode)
            run([*plugin, "baseline", "read", name, "--format", "jsonSmallerIsBetter", "--path", str(output)])
            exports = json.loads((output / f"{name}.json").read_text())
            values = validate_export(exports, summary, args.mode)
            (output / "p99.json").write_text(json.dumps(values, indent=2) + "\n")
            (output / f"{name}.json").unlink()
            result.update({"status": "passed", "workloadCount": len(matrix), "benchmarkCount": len(summary),
                           "metricCount": len(values), "steadyStateAllocationMaximum": 0 if args.mode == "allocation" else None,
                           "allocationEvidence": "positive control plus all six prepared operations at every size and precision" if args.mode == "allocation" else "instrumentation disabled"})
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
